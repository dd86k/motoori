/// Streaming JSON reader for the database loaders.
///
/// std.json builds a JSONValue DOM, which on these documents costs about eight
/// times the file in memory (84 MB for a 10.7 MB module scan) and leaves the GC
/// holding onto pools the durable data got interleaved with. The loaders only
/// ever walk a document once, in a shape they already know, so a reader that
/// hands out values in place does the job without ever materializing the DOM.
module jsonpull;

import std.format : format;
import std.utf : encode;

class JSONPullException : Exception
{
    this(string msg, size_t offset, string file = __FILE__, size_t line = __LINE__)
    {
        super(format("%s (at offset %d)", msg, offset), file, line);
    }
}

/// Reads a JSON document left to right.
///
/// Strings come back pointing into the source where they carry no escapes, and
/// into a buffer the reader reuses where they do. Either way the result is only
/// valid until the next read, so copy anything worth keeping.
struct JSONReader
{
    private const(char)[] src;
    private size_t pos;
    private char[] scratch;

    this(const(char)[] source)
    {
        src = source;
    }

    /// Byte offset the reader is at.
    size_t tell() const
    {
        return pos;
    }

    /// Go back to a position tell() handed out, to walk that part again.
    void seek(size_t offset)
    {
        pos = offset;
    }

    /// Step into an object, then call readKey until it returns false.
    void enterObject()
    {
        expect('{');
    }

    /// Step into an array, then call nextElement until it returns false.
    void enterArray()
    {
        expect('[');
    }

    /// Read the next key and consume its ':'. False once the object is closed.
    bool readKey(out const(char)[] key)
    {
        char c = next();
        if (c == '}')
        {
            ++pos;
            return false;
        }
        if (c == ',')
            ++pos;

        key = readString();
        expect(':');
        return true;
    }

    /// Position on the next element. False once the array is closed.
    bool nextElement()
    {
        char c = next();
        if (c == ']')
        {
            ++pos;
            return false;
        }
        if (c == ',')
            ++pos;
        return true;
    }

    /// Read a string value. See the struct note on how long the result lives.
    const(char)[] readString()
    {
        expect('"');

        // The common case carries no escapes and can be handed over in place
        size_t start = pos;
        while (pos < src.length)
        {
            char c = src[pos];
            if (c == '"')
            {
                const(char)[] plain = src[start..pos];
                ++pos;
                return plain;
            }
            if (c == '\\')
                return readStringEscaped(start);
            ++pos;
        }

        throw new JSONPullException("Unterminated string", start);
    }

    /// Read an integer value.
    long readInteger()
    {
        char c = next();

        bool negative = c == '-';
        if (negative || c == '+')
            ++pos;

        size_t start = pos;
        long value;
        while (pos < src.length)
        {
            c = src[pos];
            if (c < '0' || c > '9')
                break;
            value = value * 10 + (c - '0');
            ++pos;
        }

        if (pos == start)
            throw new JSONPullException("Expected a number", pos);

        return negative ? -value : value;
    }

    /// Discard the value at the current position, whatever shape it has.
    void skipValue()
    {
        char c = next();
        switch (c) {
        case '{':
            enterObject();
            const(char)[] key;
            while (readKey(key))
                skipValue();
            return;
        case '[':
            enterArray();
            while (nextElement())
                skipValue();
            return;
        case '"':
            readString();
            return;
        case 't', 'f', 'n': // true/false/null, all keyword-shaped
            while (pos < src.length && src[pos] >= 'a' && src[pos] <= 'z')
                ++pos;
            return;
        default:
            // Numbers, including the exponent and fraction forms the loaders
            // never produce but a hand-edited file might
            while (pos < src.length)
            {
                c = src[pos];
                if ((c >= '0' && c <= '9') || c == '-' || c == '+' ||
                    c == '.' || c == 'e' || c == 'E')
                {
                    ++pos;
                    continue;
                }
                break;
            }
            return;
        }
    }

    private const(char)[] readStringEscaped(size_t start)
    {
        size_t used = pos - start;
        if (scratch.length <= used) // headroom, put() below grows by doubling
            scratch.length = used < 128 ? 256 : used * 2;
        scratch[0..used] = src[start..pos];

        void put(char c)
        {
            if (used == scratch.length)
                scratch.length = scratch.length * 2;
            scratch[used++] = c;
        }

        void putPoint(dchar point)
        {
            char[4] utf8 = void;
            size_t width = encode(utf8, point);
            foreach (char e; utf8[0..width])
                put(e);
        }

        while (pos < src.length)
        {
            char c = src[pos++];
            if (c == '"')
                return scratch[0..used];
            if (c != '\\')
            {
                put(c);
                continue;
            }

            if (pos >= src.length)
                break;
            c = src[pos++];
            switch (c) {
            case '"', '\\', '/': put(c); break;
            case 'b': put('\b'); break;
            case 'f': put('\f'); break;
            case 'n': put('\n'); break;
            case 'r': put('\r'); break;
            case 't': put('\t'); break;
            case 'u':
                dchar point = readHex4();
                // A code point past the BMP arrives as a surrogate pair
                if (point >= 0xd800 && point < 0xdc00 &&
                    pos + 1 < src.length && src[pos] == '\\' && src[pos+1] == 'u')
                {
                    pos += 2;
                    dchar low = readHex4();
                    if (low >= 0xdc00 && low < 0xe000)
                        point = 0x10000 + ((point - 0xd800) << 10) + (low - 0xdc00);
                    else // not a pair after all, salvage what the second half was
                    {
                        putPoint(0xfffd);
                        point = low >= 0xd800 && low < 0xe000 ? 0xfffd : low;
                    }
                }
                else if (point >= 0xd800 && point < 0xe000)
                    point = 0xfffd;

                putPoint(point);
                break;
            default:
                throw new JSONPullException("Unknown string escape", pos - 1);
            }
        }

        throw new JSONPullException("Unterminated string", start);
    }

    private dchar readHex4()
    {
        if (pos + 4 > src.length)
            throw new JSONPullException("Truncated \\u escape", pos);

        uint value; // not a dchar: its .init is 0xffff, not zero
        foreach (char c; src[pos..pos+4])
        {
            value <<= 4;
            if (c >= '0' && c <= '9')      value |= c - '0';
            else if (c >= 'a' && c <= 'f') value |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') value |= c - 'A' + 10;
            else throw new JSONPullException("Bad hexadecimal in \\u escape", pos);
        }

        pos += 4;
        return cast(dchar)value;
    }

    /// Next non-whitespace character, without consuming it.
    private char next()
    {
        while (pos < src.length)
        {
            char c = src[pos];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
            {
                ++pos;
                continue;
            }
            return c;
        }

        throw new JSONPullException("Unexpected end of document", pos);
    }

    private void expect(char c)
    {
        if (next() != c)
            throw new JSONPullException(format("Expected '%s'", c), pos);
        ++pos;
    }
}

unittest
{
    static string[] keysOf(string document)
    {
        JSONReader r = JSONReader(document);
        string[] keys;
        const(char)[] key;
        r.enterObject();
        while (r.readKey(key))
        {
            keys ~= key.idup;
            r.skipValue();
        }
        return keys;
    }

    assert(keysOf(`{}`).length == 0);
    assert(keysOf(`{"a":1,"b":"x","c":[1,2,{"d":null}],"e":{},"f":true,"g":-1.5e3}`)
        == ["a", "b", "c", "e", "f", "g"]);

    // Strings come back in place when they carry no escapes
    {
        string document = `{"k":"plain"}`;
        JSONReader r = JSONReader(document);
        const(char)[] key;
        r.enterObject();
        assert(r.readKey(key) && key == "k");
        const(char)[] value = r.readString();
        assert(value == "plain");
        assert(value.ptr == document.ptr + 6);
    }

    static const(char)[] unescape(string literal)
    {
        JSONReader r = JSONReader(literal);
        return r.readString();
    }

    assert(unescape(`"a\"b"`)        == "a\"b");
    assert(unescape(`"a\\b"`)        == `a\b`);
    assert(unescape(`"a\/b"`)        == "a/b");
    assert(unescape(`"\b\f\n\r\t"`)  == "\b\f\n\r\t");
    assert(unescape(`"\u00e9"`)     == "é");        // BMP escape
    assert(unescape(`"\u20ac"`)     == "€");
    assert(unescape(`"\ud83d\ude00"`) == "😀"); // surrogate pair
    assert(unescape(`"\ud800"`)      == "�");      // lone high surrogate
    assert(unescape(`"\udc00"`)      == "�");      // lone low surrogate
    assert(unescape(`"tail\nafter"`) == "tail\nafter");

    // Arrays, including the empty and nested cases
    {
        JSONReader r = JSONReader(`[ 1, 2 , 3 ]`);
        long[] values;
        r.enterArray();
        while (r.nextElement())
            values ~= r.readInteger();
        assert(values == [1, 2, 3]);
    }
    {
        JSONReader r = JSONReader(`[]`);
        r.enterArray();
        assert(r.nextElement() == false);
    }
    {
        JSONReader r = JSONReader(`{"n":-42,"m":0}`);
        const(char)[] key;
        r.enterObject();
        assert(r.readKey(key) && key == "n");
        assert(r.readInteger() == -42);
        assert(r.readKey(key) && key == "m");
        assert(r.readInteger() == 0);
        assert(r.readKey(key) == false);
    }

    // Malformed input is rejected rather than silently accepted
    static bool rejects(void delegate() walk)
    {
        try walk();
        catch (JSONPullException)
            return true;
        return false;
    }

    assert(rejects({ JSONReader r = JSONReader(`"unterminated`); r.readString(); }));
    assert(rejects({ JSONReader r = JSONReader(`"\q"`); r.readString(); }));
    assert(rejects({ JSONReader r = JSONReader(`"\u00g0"`); r.readString(); }));
    assert(rejects({ JSONReader r = JSONReader(`[1`); r.enterArray(); r.nextElement(); r.readInteger(); r.nextElement(); }));
    assert(rejects({ JSONReader r = JSONReader(`{"a" 1}`); const(char)[] k; r.enterObject(); r.readKey(k); }));
    assert(rejects({ JSONReader r = JSONReader(`  `); r.enterObject(); }));
}
