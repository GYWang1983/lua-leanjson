/*
 * Ordinary-string scanning adapted from json_next_string_token in OpenResty
 * lua-cjson, pinned upstream revision 617164a0fe3bb647128178f9caefb304b8573bb6.
 * Unlike the original loop, return a bounded source span without copying it.
 * Quotes, escapes, controls and strict UTF-8 boundaries stay with the validator.
 *
 * Copyright (c) 2010-2012 Mark Pulford <mark@kyne.com.au>
 * Copyright (c) 2026 LeanJSON contributors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
#include <stddef.h>
#include <stdint.h>

size_t leanjson_cjson_scan_plain(const uint8_t *bytes, size_t len,
                                uint32_t raw_bytes, uint32_t *needs_escape)
{
    size_t i = 0;
    uint32_t flags = 0;
    while (i < len) {
        uint8_t ch = bytes[i];
        if (ch == '"' || ch == '\\' || ch < 0x20 || (!raw_bytes && ch >= 0x80))
            break;
        flags |= ch == '/' || ch == 0x7f;
        i++;
    }
    *needs_escape = flags;
    return i;
}
