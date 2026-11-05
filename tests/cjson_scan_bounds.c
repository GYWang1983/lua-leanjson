/* Guard-page and sanitizer coverage for the length-bounded C scan kernel. */
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

size_t leanjson_cjson_scan_plain(const uint8_t *, size_t, uint32_t, uint32_t *);

int main(void)
{
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    uint8_t *memory = mmap(NULL, page * 2, PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(memory != MAP_FAILED);
    memset(memory, 'x', page);
    assert(mprotect(memory + page, page, PROT_NONE) == 0);
    for (size_t len = 0; len <= page; len++) {
        uint32_t escape = 99;
        uint8_t *bytes = memory + page - len;
        assert(leanjson_cjson_scan_plain(bytes, len, 1, &escape) == len);
        assert(escape == 0);
        if (len != 0) {
            bytes[len - 1] = '/';
            assert(leanjson_cjson_scan_plain(bytes, len, 1, &escape) == len);
            assert(escape == 1);
            bytes[len - 1] = '"';
            assert(leanjson_cjson_scan_plain(bytes, len, 1, &escape) == len - 1);
            bytes[len - 1] = 'x';
        }
    }
    uint32_t escape;
    assert(leanjson_cjson_scan_plain((const uint8_t *)"a\\b", 3, 1, &escape) == 1);
    assert(leanjson_cjson_scan_plain((const uint8_t *)"\x7f", 1, 1, &escape) == 1 && escape == 1);
    assert(leanjson_cjson_scan_plain((const uint8_t *)"\xff", 1, 1, &escape) == 1);
    assert(leanjson_cjson_scan_plain((const uint8_t *)"\xff", 1, 0, &escape) == 0);
    assert(leanjson_cjson_scan_plain((const uint8_t *)"\n", 1, 1, &escape) == 0);
    assert(munmap(memory, page * 2) == 0);
    puts("C scanner bounds: every length through guard-page boundary passed");
    return 0;
}
