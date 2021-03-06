/**
This module implements ScriptString. However, host applications should work with D strings by converting
the ScriptAny directly to string with toString().

────────────────────────────────────────────────────────────────────────────────

Copyright (C) 2021 pillager86.rf.gd

This program is free software: you can redistribute it and/or modify it under 
the terms of the GNU General Public License as published by the Free Software 
Foundation, either version 3 of the License, or (at your option) any later 
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with 
this program.  If not, see <https://www.gnu.org/licenses/>.
*/
module mildew.types.string;

import mildew.types.object;

/**
 * Encapsulates a string. It is stored internally as UTF-8 and treated as such
 * except during iteration, in which dchar code points are the iteration element.
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

private:
    string _string;
}