/* -*-pgsql-c-*- */
/*
 * Scanner for the configuration file
 *
 * Copyright (c) 2000-2009, PostgreSQL Global Development Group
 *
 * $PostgreSQL: pgsql/src/backend/utils/misc/guc-file.l,v 1.59 2009/04/09 14:21:02 tgl Exp $
 */

%{

#include "postgres.h"

#include <ctype.h>
#include <unistd.h>

#include "miscadmin.h"
#include "storage/fd.h"
#include "utils/guc.h"

#define unify_version(a,b,c) ((a<<16)+(b<<8)+c)
#if unify_version(YY_FLEX_MAJOR_VERSION,YY_FLEX_MINOR_VERSION,YY_FLEX_SUBMINOR_VERSION) < unify_version(2,5,35)
int GUC_yylex_destroy  (void);
int GUC_yyget_lineno  (void);
FILE *GUC_yyget_in  (void);
FILE *GUC_yyget_out  (void);
int GUC_yyget_leng  (void);
char *GUC_yyget_text  (void);
void GUC_yyset_lineno (int  line_number );
void GUC_yyset_in (FILE *  in_str );
void GUC_yyset_out (FILE *  out_str );
int GUC_yyget_debug  (void);
void GUC_yyset_debug (int  bdebug );
int GUC_yylex_destroy  (void);
#endif




/*
 * flex emits a yy_fatal_error() function that it calls in response to
 * critical errors like malloc failure, file I/O errors, and detection of
 * internal inconsistency.  That function prints a message and calls exit().
 * Mutate it to instead call our handler, which jumps out of the parser.
 */
#undef fprintf
#define fprintf(file, fmt, msg) GUC_flex_fatal(msg)

enum
{
	GUC_ID = 1,
	GUC_STRING = 2,
	GUC_INTEGER = 3,
	GUC_REAL = 4,
	GUC_EQUALS = 5,
	GUC_UNQUOTED_STRING = 6,
	GUC_QUALIFIED_ID = 7,
	GUC_EOL = 99,
	GUC_ERROR = 100
};

static unsigned int ConfigFileLineno;
static const char *GUC_flex_fatal_errmsg;
static sigjmp_buf *GUC_flex_fatal_jmp;

/* flex fails to supply a prototype for yylex, so provide one */
int GUC_yylex(void);

static int GUC_flex_fatal(const char *msg);

static char *GUC_scanstr(const char *s);

%}

%option 8bit
%option never-interactive
%option nodefault
%option noinput
%option nounput
%option noyywrap
%option prefix="GUC_yy"


SIGN            ("-"|"+")
DIGIT           [0-9]
HEXDIGIT        [0-9a-fA-F]

UNIT_LETTER     [a-zA-Z]

INTEGER         {SIGN}?({DIGIT}+|0x{HEXDIGIT}+){UNIT_LETTER}*

EXPONENT        [Ee]{SIGN}?{DIGIT}+
REAL            {SIGN}?{DIGIT}*"."{DIGIT}*{EXPONENT}?

LETTER          [A-Za-z_\200-\377]
LETTER_OR_DIGIT [A-Za-z_0-9\200-\377]

ID              {LETTER}{LETTER_OR_DIGIT}*
QUALIFIED_ID    {ID}"."{ID}

UNQUOTED_STRING {LETTER}({LETTER_OR_DIGIT}|[-._:/])*
STRING          \'([^'\\\n]|\\.|\'\')*\'

%%

\n              ConfigFileLineno++; return GUC_EOL;
[ \t\r]+        /* eat whitespace */
#.*             /* eat comment (.* matches anything until newline) */

{ID}            return GUC_ID;
{QUALIFIED_ID}  return GUC_QUALIFIED_ID;
{STRING}        return GUC_STRING;
{UNQUOTED_STRING} return GUC_UNQUOTED_STRING;
{INTEGER}       return GUC_INTEGER;
{REAL}          return GUC_REAL;
=               return GUC_EQUALS;

.               return GUC_ERROR;

%%



/*
 * Exported function to read and process the configuration file. The
 * parameter indicates in what context the file is being read --- either
 * postmaster startup (including standalone-backend startup) or SIGHUP.
 * All options mentioned in the configuration file are set to new values.
 * If an error occurs, no values will be changed.
 */
void
ProcessConfigFile(GucContext context)
{
	int			elevel;
	ConfigVariable *item,
				   *head,
				   *tail;
	char	   *cvc = NULL;
	struct config_string *cvc_struct;
	const char *envvar;
	int			i;

	Assert(context == PGC_POSTMASTER || context == PGC_SIGHUP);

	if (context == PGC_SIGHUP)
	{
		/*
		 * To avoid cluttering the log, only the postmaster bleats loudly
		 * about problems with the config file.
		 */
		elevel = IsUnderPostmaster ? DEBUG2 : LOG;
	}
	else
		elevel = ERROR;

	/* Parse the file into a list of option names and values */
	head = tail = NULL;

	if (!ParseConfigFile(ConfigFileName, NULL,
						 0, elevel,
						 &head, &tail))
		goto cleanup_list;

	Assert(gp_replication_config_filename);

	if (!ParseConfigFile(gp_replication_config_filename, NULL,
						 0, elevel,
						 &head, &tail))
		goto cleanup_list;

	/*
	 * We need the proposed new value of custom_variable_classes to check
	 * custom variables with.  ParseConfigFile ensured that if it's in
	 * the file, it's first in the list.  But first check to see if we
	 * have an active value from the command line, which should override
	 * the file in any case.  (Since there's no relevant env var, the
	 * only possible nondefault sources are the file and ARGV.)
	 */
	cvc_struct = (struct config_string *)
		find_option("custom_variable_classes", false, elevel);
	if (cvc_struct && cvc_struct->gen.reset_source > PGC_S_FILE)
	{
		cvc = guc_strdup(elevel, cvc_struct->reset_val);
		if (cvc == NULL)
			goto cleanup_list;
	}
	else if (head != NULL &&
			 guc_name_compare(head->name, "custom_variable_classes") == 0)
	{
		/*
		 * Need to canonicalize the value via the assign hook.  Casting away
		 * const is a bit ugly, but we know the result is malloc'd.
		 */
		cvc = (char *) assign_custom_variable_classes(head->value,
													  false, PGC_S_FILE);
		if (cvc == NULL)
		{
			ereport(elevel,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("invalid value for parameter \"%s\": \"%s\"",
							head->name, head->value)));
			goto cleanup_list;
		}
	}

	/*
	 * Mark all extant GUC variables as not present in the config file.
	 * We need this so that we can tell below which ones have been removed
	 * from the file since we last processed it.
	 */
	for (i = 0; i < num_guc_variables; i++)
	{
		struct config_generic *gconf = guc_variables[i];

		gconf->status &= ~GUC_IS_IN_FILE;
	}

	/*
	 * Check if all options are valid.  As a side-effect, the GUC_IS_IN_FILE
	 * flag is set on each GUC variable mentioned in the list.
	 */
	for (item = head; item; item = item->next)
	{
		char *sep = strchr(item->name, GUC_QUALIFIER_SEPARATOR);

		if (sep)
		{
			/*
			 * We have to consider three cases for custom variables:
			 *
			 * 1. The class name is not valid according to the (new) setting
			 * of custom_variable_classes.  If so, reject.  We don't care
			 * which side is at fault.
			 */
			if (!is_custom_class(item->name, sep - item->name, cvc))
			{
				ereport(elevel,
						(errcode(ERRCODE_UNDEFINED_OBJECT),
						 errmsg("unrecognized configuration parameter \"%s\"",
								item->name)));
				goto cleanup_list;
			}
			/*
			 * 2. There is no GUC entry.  If we called set_config_option then
			 * it would make a placeholder, which we don't want to do yet,
			 * since we could still fail further down the list.  Do nothing
			 * (assuming that making the placeholder will succeed later).
			 */
			if (find_option(item->name, false, elevel) == NULL)
				continue;
			/*
			 * 3. There is already a GUC entry (either real or placeholder) for
			 * the variable.  In this case we should let set_config_option
			 * check it, since the assignment could well fail if it's a real
			 * entry.
			 */
		}

		if (!set_config_option(item->name, item->value, context,
							   PGC_S_FILE, GUC_ACTION_SET, false))
			goto cleanup_list;
	}

	/*
	 * Check for variables having been removed from the config file, and
	 * revert their reset values (and perhaps also effective values) to the
	 * boot-time defaults.  If such a variable can't be changed after startup,
	 * just throw a warning and continue.  (This is analogous to the fact that
	 * set_config_option only throws a warning for a new but different value.
	 * If we wanted to make it a hard error, we'd need an extra pass over the
	 * list so that we could throw the error before starting to apply
	 * changes.)
	 */
	for (i = 0; i < num_guc_variables; i++)
	{
		struct config_generic *gconf = guc_variables[i];
		GucStack   *stack;

		if (gconf->reset_source != PGC_S_FILE ||
			(gconf->status & GUC_IS_IN_FILE))
			continue;
		if (gconf->context < PGC_SIGHUP)
		{
			ereport(elevel,
					(errcode(ERRCODE_CANT_CHANGE_RUNTIME_PARAM),
					 errmsg("attempted change of parameter \"%s\" ignored",
							gconf->name),
					 errdetail("This parameter cannot be changed after server start.")));
			continue;
		}

		/*
		 * Reset any "file" sources to "default", else set_config_option
		 * will not override those settings.
		 */
		if (gconf->reset_source == PGC_S_FILE)
			gconf->reset_source = PGC_S_DEFAULT;
		if (gconf->source == PGC_S_FILE)
			gconf->source = PGC_S_DEFAULT;
		for (stack = gconf->stack; stack; stack = stack->prev)
		{
			if (stack->source == PGC_S_FILE)
				stack->source = PGC_S_DEFAULT;
		}

		/* Now we can re-apply the wired-in default */
		set_config_option(gconf->name, NULL, context, PGC_S_DEFAULT,
						  GUC_ACTION_SET, true);
	}

	/*
	 * Restore any variables determined by environment variables.  This
	 * is a no-op except in the case where one of these had been in the
	 * config file and is now removed.  PGC_S_ENV_VAR will override the
	 * wired-in default we just applied, but cannot override any other source.
	 *
	 * Keep this list in sync with InitializeGUCOptions()!
	 * PGPORT can be ignored, because it cannot be changed without restart.
	 * We assume rlimit hasn't changed, either.
	 */
	envvar = getenv("PGDATESTYLE");
	if (envvar != NULL)
		set_config_option("datestyle", envvar, PGC_POSTMASTER,
						  PGC_S_ENV_VAR, GUC_ACTION_SET, true);

	envvar = getenv("PGCLIENTENCODING");
	if (envvar != NULL)
		set_config_option("client_encoding", envvar, PGC_POSTMASTER,
						  PGC_S_ENV_VAR, GUC_ACTION_SET, true);


	/* If we got here all the options checked out okay, so apply them. */
	for (item = head; item; item = item->next)
	{
		if (set_config_option(item->name, item->value, context,
			   					 PGC_S_FILE, GUC_ACTION_SET, true))
		{
			set_config_sourcefile(item->name, item->filename,
								  item->sourceline);
		}
	}

	/* Remember when we last successfully loaded the config file. */
	PgReloadTime = GetCurrentTimestamp();

 cleanup_list:
	FreeConfigVariables(head);
	if (cvc)
		free(cvc);
}

/*
 * Flex fatal errors bring us here.  Stash the error message and jump back to
 * ParseConfigFp().  Assume all msg arguments point to string constants; this
 * holds for flex 2.5.31 (earliest we support) and flex 2.5.35 (latest as of
 * this writing).  Otherwise, we would need to copy the message.
 *
 * We return "int" since this takes the place of calls to fprintf().
*/
static int
GUC_flex_fatal(const char *msg)
{
	GUC_flex_fatal_errmsg = msg;
	siglongjmp(*GUC_flex_fatal_jmp, 1);
	return 0;	/* keep compiler quiet */
}

/*
 * See next function for details. This one will just work with a config_file
 * name rather than an already opened File Descriptor
 */
bool
ParseConfigFile(const char *config_file, const char *calling_file,
				int depth, int elevel,
				ConfigVariable **head_p,
				ConfigVariable **tail_p)
{
	bool		OK = true;
	FILE	   *fp;
	char		abs_path[MAXPGPATH];

	/*
	 * Reject too-deep include nesting depth.  This is just a safety check
	 * to avoid dumping core due to stack overflow if an include file loops
	 * back to itself.  The maximum nesting depth is pretty arbitrary.
	 */
	if (depth > 10)
	{
		ereport(elevel,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("could not open configuration file \"%s\": maximum nesting depth exceeded",
						config_file)));

		return false;
	}

	/*
	 * If config_file is a relative path, convert to absolute.  We consider
	 * it to be relative to the directory holding the calling file.
	 */
	if (!is_absolute_path(config_file))
	{
		if (calling_file != NULL)
		{
			strlcpy(abs_path, calling_file, sizeof(abs_path));
			get_parent_directory(abs_path);
			join_path_components(abs_path, abs_path, config_file);
			canonicalize_path(abs_path);
			config_file = abs_path;
		}
		else
		{
			/*
			 * calling_file is NULL, we make an absolute path from $PGDATA
			 */
			join_path_components(abs_path, data_directory, config_file);
			canonicalize_path(abs_path);
			config_file = abs_path;
		}
	}

	fp = AllocateFile(config_file, "r");
	if (!fp)
	{
		ereport(elevel,
				(errcode_for_file_access(),
				 errmsg("could not open configuration file \"%s\": %m",
						config_file)));

		return false;
	}

	OK = ParseConfigFp(fp, config_file, depth, elevel, head_p, tail_p);

	FreeFile(fp);

	return OK;
}

/*
 * Read and parse a single configuration file.  This function recurses
 * to handle "include" directives.
 *
 * Input parameters:
 *	fp: file pointer from AllocateFile for the configuration file to parse
 *	config_file: absolute or relative path of file to read
 *	depth: recursion depth (used only to prevent infinite recursion)
 *	elevel: error logging level determined by ProcessConfigFile()
 * Output parameters:
 *	head_p, tail_p: head and tail of linked list of name/value pairs
 *
 * *head_p and *tail_p must be initialized to NULL before calling the outer
 * recursion level.  On exit, they contain a list of name-value pairs read
 * from the input file(s).
 *
 * Returns TRUE if successful, FALSE if an error occurred.  The error has
 * already been ereport'd, it is only necessary for the caller to clean up
 * its own state and release the ConfigVariable list.
 *
 * Note: if elevel >= ERROR then an error will not return control to the
 * caller, and internal state such as open files will not be cleaned up.
 * This case occurs only during postmaster or standalone-backend startup,
 * where an error will lead to immediate process exit anyway; so there is
 * no point in contorting the code so it can clean up nicely.
 */
bool
ParseConfigFp(FILE *fp, const char *config_file, int depth, int elevel,
			  ConfigVariable **head_p, ConfigVariable **tail_p)
{
	volatile bool OK = true;
	unsigned int save_ConfigFileLineno = ConfigFileLineno;
	sigjmp_buf *save_GUC_flex_fatal_jmp = GUC_flex_fatal_jmp;
	sigjmp_buf	flex_fatal_jmp;
	volatile YY_BUFFER_STATE lex_buffer = NULL;
	int			token;

	if (sigsetjmp(flex_fatal_jmp, 1) == 0)
		GUC_flex_fatal_jmp = &flex_fatal_jmp;
	else
	{
		/*
		 * Regain control after a fatal, internal flex error.  It may have
		 * corrupted parser state.  Consequently, abandon the file, but trust
		 * that the state remains sane enough for yy_delete_buffer().
		 */
		elog(elevel, "%s at file \"%s\" line %u",
			 GUC_flex_fatal_errmsg, config_file, ConfigFileLineno);
		OK = false;
		goto cleanup_exit;
	}

	/*
	 * Parse
	 */
	ConfigFileLineno = 1;

	lex_buffer = yy_create_buffer(fp, YY_BUF_SIZE);
	yy_switch_to_buffer(lex_buffer);

	/* This loop iterates once per logical line */
	while ((token = yylex()))
	{
		char	   *opt_name = NULL;
		char	   *opt_value = NULL;
		ConfigVariable *item;

		if (token == GUC_EOL)	/* empty or comment line */
			continue;

		/* first token on line is option name */
		if (token != GUC_ID && token != GUC_QUALIFIED_ID)
			goto parse_error;
		opt_name = pstrdup(yytext);

		/* next we have an optional equal sign; discard if present */
		token = yylex();
		if (token == GUC_EQUALS)
			token = yylex();

		/* now we must have the option value */
		if (token != GUC_ID &&
			token != GUC_STRING &&
			token != GUC_INTEGER &&
			token != GUC_REAL &&
			token != GUC_UNQUOTED_STRING)
			goto parse_error;
		if (token == GUC_STRING)	/* strip quotes and escapes */
			opt_value = GUC_scanstr(yytext);
		else
			opt_value = pstrdup(yytext);

		/* now we'd like an end of line, or possibly EOF */
		token = yylex();
		if (token != GUC_EOL)
		{
			if (token != 0)
				goto parse_error;
			/* treat EOF like \n for line numbering purposes, cf bug 4752 */
			ConfigFileLineno++;
		}

		/* OK, process the option name and value */
		if (guc_name_compare(opt_name, "include") == 0)
		{
			/*
			 * An include directive isn't a variable and should be processed
			 * immediately.
			 */
			if (!ParseConfigFile(opt_value, config_file,
								 depth + 1, elevel,
								 head_p, tail_p))
			{
				pfree(opt_name);
				pfree(opt_value);
				OK = false;
				goto cleanup_exit;
			}
			yy_switch_to_buffer(lex_buffer);
			pfree(opt_name);
			pfree(opt_value);
		}
		else if (guc_name_compare(opt_name, "custom_variable_classes") == 0)
		{
			/*
			 * This variable must be processed first as it controls
			 * the validity of other variables; so it goes at the head
			 * of the result list.  If we already found a value for it,
			 * replace with this one.
			 */
			item = *head_p;
			if (item != NULL &&
				guc_name_compare(item->name, "custom_variable_classes") == 0)
			{
				/* replace existing head item */
				pfree(item->name);
				pfree(item->value);
				item->name = opt_name;
				item->value = opt_value;
				item->filename = pstrdup(config_file);
				item->sourceline = ConfigFileLineno-1;
			}
			else
			{
				/* prepend to list */
				item = palloc(sizeof *item);
				item->name = opt_name;
				item->value = opt_value;
				item->filename = pstrdup(config_file);
				item->sourceline = ConfigFileLineno-1;
				item->next = *head_p;
				*head_p = item;
				if (*tail_p == NULL)
					*tail_p = item;
			}
		}
		else
		{
			/* ordinary variable, append to list */
			item = palloc(sizeof *item);
			item->name = opt_name;
			item->value = opt_value;
			item->filename = pstrdup(config_file);
			item->sourceline = ConfigFileLineno-1;
			item->next = NULL;
			if (*head_p == NULL)
				*head_p = item;
			else
				(*tail_p)->next = item;
			*tail_p = item;
		}

		/* break out of loop if read EOF, else loop for next line */
		if (token == 0)
			break;
	}

	/* successful completion of parsing */
	goto cleanup_exit;

 parse_error:
	if (token == GUC_EOL || token == 0)
		ereport(elevel,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("syntax error in file \"%s\" line %u, near end of line",
						config_file, ConfigFileLineno - 1)));
	else
		ereport(elevel,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("syntax error in file \"%s\" line %u, near token \"%s\"", 
						config_file, ConfigFileLineno, yytext)));
	OK = false;

cleanup_exit:
	yy_delete_buffer(lex_buffer);
	/* Each recursion level must save and restore these static variables. */
	ConfigFileLineno = save_ConfigFileLineno;
	GUC_flex_fatal_jmp = save_GUC_flex_fatal_jmp;
	return OK;
}


/*
 * Free a list of ConfigVariables, including the names and the values
 */
void
FreeConfigVariables(ConfigVariable *list)
{
	ConfigVariable *item;

	item = list;
	while (item)
	{
		ConfigVariable *next = item->next;

		pfree(item->name);
		pfree(item->value);
		pfree(item->filename);
		pfree(item);
		item = next;
	}
}


/*
 *		scanstr
 *
 * Strip the quotes surrounding the given string, and collapse any embedded
 * '' sequences and backslash escapes.
 *
 * the string returned is palloc'd and should eventually be pfree'd by the
 * caller.
 */
static char *
GUC_scanstr(const char *s)
{
	char	   *newStr;
	int			len,
				i,
				j;

	Assert(s != NULL && s[0] == '\'');
	len = strlen(s);
	Assert(len >= 2);
	Assert(s[len-1] == '\'');

	/* Skip the leading quote; we'll handle the trailing quote below */
	s++, len--;

	/* Since len still includes trailing quote, this is enough space */
	newStr = palloc(len);

	for (i = 0, j = 0; i < len; i++)
	{
		if (s[i] == '\\')
		{
			i++;
			switch (s[i])
			{
				case 'b':
					newStr[j] = '\b';
					break;
				case 'f':
					newStr[j] = '\f';
					break;
				case 'n':
					newStr[j] = '\n';
					break;
				case 'r':
					newStr[j] = '\r';
					break;
				case 't':
					newStr[j] = '\t';
					break;
				case '0':
				case '1':
				case '2':
				case '3':
				case '4':
				case '5':
				case '6':
				case '7':
					{
						int			k;
						long		octVal = 0;

						for (k = 0;
							 s[i + k] >= '0' && s[i + k] <= '7' && k < 3;
							 k++)
							octVal = (octVal << 3) + (s[i + k] - '0');
						i += k - 1;
						newStr[j] = ((char) octVal);
					}
					break;
				default:
					newStr[j] = s[i];
					break;
			}					/* switch */
		}
		else if (s[i] == '\'' && s[i+1] == '\'')
		{
			/* doubled quote becomes just one quote */
			newStr[j] = s[++i];
		}
		else
			newStr[j] = s[i];
		j++;
	}

	/* We copied the ending quote to newStr, so replace with \0 */
	Assert(j > 0 && j <= len);
	newStr[--j] = '\0';

	return newStr;
}
