/**
 * This module implements ScriptString. However, host applications should work with D strings by converting
 * the ScriptAny directly to string.
 */
module mildew.types.string;

import mildew.types.object;

/**
 * Encapsulates a string. It is stored internally as UTF-8 but is cast to UTF-16 for the
 * methods that access individual array indices. TODO: code point iteration
 */
class ScriptString : ScriptObject
{
    import std.conv: to;
    import mildew.types.any: ScriptAny;
public:
    /**
     * Constructs a new ScriptString out of a UTF-8 D string
     */
    this(in string str)
    {
        import mildew.types.bindings: getStringPrototype;
        super("string", getStringPrototype, null);
        _string = str;
    }

    /**
     * Returns the actual D string contained
     */
    override string toString() const
    {
        return _string;
    }

    /**
     * Gets the wstring UTF-16 representation
     */
    wstring getWString() const
    {
        return _string.to!wstring;
    }

    /**
     * This override allows for the length field
     */
    override ScriptAny lookupField(in string name)
    {
        if(name == "length")
            return ScriptAny(getWString.length);
        else
            return super.lookupField(name);
    }

    // methods to bind

package:
    // TODO catch utf exceptions or process sequentially
    wchar charAt(size_t index)
    {
        if(index >= getWString.length)
            return '\0';
        return getWString[index];
    }

    ushort charCodeAt(size_t index)
    {
        if(index >= getWString.length)
            return 0;
        return cast(ushort)(getWString[index]);
    }

private:
    string _string;
}