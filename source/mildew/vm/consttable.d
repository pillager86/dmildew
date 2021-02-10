module mildew.vm.consttable;

import mildew.types.any;

/// a table of consts to be sent to virtual machine so that instructions that refer to consts can be executed
class ConstTable
{
public:
    /// add a possibly new value to table and return its index.
    size_t addValue(ScriptAny value)
    {
        // already in table?
        if(value in _lookup)
        {
            return _lookup[value];
        }
        // have to add new one
        auto location = _constants.length;
        _lookup[value] = location;
        _constants ~= value;
        return location;
    }

    /// same as addValue but returns an uint for easy encoding
    uint addValueUint(ScriptAny value)
    {
        return cast(uint)addValue(value);
    }

    /// get a specific constant
    ScriptAny get(size_t index) const
    {
        import std.format: format;
        if(index >= _constants.length)
            throw new Exception(format("index %s is greater than %s", index, _constants.length));
        return cast(immutable)_constants[index];
    }

private:
    ScriptAny[] _constants;
    size_t[ScriptAny] _lookup;
}