/**
 * This module implements the exception classes that can be thrown by the script. These should be
 * caught and printed to provide meaningful information about why an exception was thrown while
 * parsing or executing a script.
 */
module mildew.exceptions;

import mildew.lexer: Token;

/**
 * This exception is thrown by the Lexer and Parser when an error occurs during tokenizing or parsing.
 */
class ScriptCompileException : Exception
{
    /**
     * Constructor. Token may be invalid when thrown by the Lexer.
     */
    this(string msg, Token tok, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
        token = tok;
    }

    /**
     * Returns a string that represents the error message and the token and the location of the token where
     * the error occurred.
     */
    override string toString() const
    {
        import std.format: format;
        return format("ScriptCompileException: %s at token %s at %s", msg, token, token.position);
    }

    /**
     * The offending token. This may have an invalid position field depending on why the error was thrown.
     */
    Token token;
}

/**
 * This exception is generated by the new keyword and stored in a VisitResult that propagates through the
 * call stack so that traceback line numbers in the script can be added to it. It is only thrown when
 * the calls get back to Interpreter.evaluate. This exception can also be "thrown" and caught
 * by the script.
 */
class ScriptRuntimeException : Exception
{
    import mildew.nodes: Node, StatementNode;
    import mildew.types.any: ScriptAny;
    
    /// Constructor
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }

    /// Returns a string containing the script code traceback as well as exception message.
    override string toString() const
    {
        import std.conv: to;

        string str = "ScriptRuntimeException: " ~ msg ~ "\n";
        foreach(tb ; scriptTraceback)
        {
            str ~= " at line " ~ tb.line.to!string ~ ":" ~ tb.toString() ~ "\n";
        }
        return str;
    }

    /// A chain of statement nodes where the exception occurred
    StatementNode[] scriptTraceback;
    /// If it is thrown by a script, this is the value that was thrown
    ScriptAny thrownValue = ScriptAny.UNDEFINED; 
}
