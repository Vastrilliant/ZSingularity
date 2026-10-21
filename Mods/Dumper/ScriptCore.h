#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <mach-o/dyld.h>

typedef struct { char *p; size_t n, cap; } ZB;

static void zb_init(ZB *b) { b->p = NULL; b->n = 0; b->cap = 0; }
static void zb_free(ZB *b) { free(b->p); zb_init(b); }
static void zb_reset(ZB *b) { b->n = 0; if (b->p) b->p[0] = 0; }
static bool zb_reserve(ZB *b, size_t extra) {
    if (b->n + extra + 1 <= b->cap) return true;
    size_t cap = b->cap ? b->cap : 256;
    while (cap < b->n + extra + 1) cap *= 2;
    char *p = (char *)realloc(b->p, cap);
    if (!p) return false;
    b->p = p; b->cap = cap;
    return true;
}
static void zb_putn(ZB *b, const char *s, size_t n) {
    if (!zb_reserve(b, n)) return;
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = 0;
}
static void zb_puts(ZB *b, const char *s) { if (s) zb_putn(b, s, strlen(s)); }
static void zb_putc(ZB *b, char c) { zb_putn(b, &c, 1); }
static void zb_printf(ZB *b, const char *fmt, ...) {
    char tmp[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n < sizeof tmp) { zb_putn(b, tmp, (size_t)n); return; }
    if (!zb_reserve(b, (size_t)n)) return;
    va_start(ap, fmt);
    vsnprintf(b->p + b->n, (size_t)n + 1, fmt, ap);
    va_end(ap);
    b->n += (size_t)n;
}

static size_t zs_json_escape_into(ZB *o, const uint8_t *s, size_t n) {
    static const char hex[] = "0123456789ABCDEF";
    size_t start = o->n;
    size_t i = 0;
    while (i < n) {
        uint8_t c = s[i];
        if (c < 0x80) {
            i++;
            switch (c) {
                case '\\': zb_putn(o, "\\\\", 2); continue;
                case '\b': zb_putn(o, "\\b", 2); continue;
                case '\t': zb_putn(o, "\\t", 2); continue;
                case '\n': zb_putn(o, "\\n", 2); continue;
                case '\f': zb_putn(o, "\\f", 2); continue;
                case '\r': zb_putn(o, "\\r", 2); continue;
                default: break;
            }
            if (c < 0x20 || c == 0x7f || c == '&' || c == '\'' || c == '+' || c == '<' || c == '>' || c == '`' || c == '"') {
                char e[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
                zb_putn(o, e, 6);
            } else {
                zb_putc(o, (char)c);
            }
            continue;
        }
        uint32_t cp = 0xFFFD;
        size_t len = 1;
        if (c >= 0xC2 && c <= 0xDF && i + 1 < n && (s[i + 1] & 0xC0) == 0x80) {
            cp = ((uint32_t)(c & 0x1F) << 6) | (s[i + 1] & 0x3F);
            len = 2;
        } else if (c >= 0xE0 && c <= 0xEF && i + 2 < n && (s[i + 1] & 0xC0) == 0x80 && (s[i + 2] & 0xC0) == 0x80) {
            uint32_t v = ((uint32_t)(c & 0x0F) << 12) | ((uint32_t)(s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F);
            if (v >= 0x800 && !(v >= 0xD800 && v <= 0xDFFF)) { cp = v; len = 3; }
        } else if (c >= 0xF0 && c <= 0xF4 && i + 3 < n && (s[i + 1] & 0xC0) == 0x80 && (s[i + 2] & 0xC0) == 0x80 && (s[i + 3] & 0xC0) == 0x80) {
            uint32_t v = ((uint32_t)(c & 0x07) << 18) | ((uint32_t)(s[i + 1] & 0x3F) << 12) | ((uint32_t)(s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F);
            if (v >= 0x10000 && v <= 0x10FFFF) { cp = v; len = 4; }
        }
        i += len;
        uint16_t units[2];
        int nu = 1;
        if (cp >= 0x10000) {
            cp -= 0x10000;
            units[0] = (uint16_t)(0xD800 + (cp >> 10));
            units[1] = (uint16_t)(0xDC00 + (cp & 0x3FF));
            nu = 2;
        } else {
            units[0] = (uint16_t)cp;
        }
        for (int k = 0; k < nu; k++) {
            char e[6] = {'\\', 'u', hex[units[k] >> 12], hex[(units[k] >> 8) & 15], hex[(units[k] >> 4) & 15], hex[units[k] & 15]};
            zb_putn(o, e, 6);
        }
    }
    return o->n - start;
}

typedef struct {
    void *(*domain_get)(void);
    void **(*domain_get_assemblies)(const void *, size_t *);
    const void *(*assembly_get_image)(const void *);
    size_t (*image_get_class_count)(const void *);
    const void *(*image_get_class)(const void *, size_t);
    const char *(*class_get_name)(void *);
    const char *(*class_get_namespace)(void *);
    void *(*class_get_declaring_type)(void *);
    const void *(*class_get_type)(void *);
    bool (*class_is_valuetype)(const void *);
    bool (*class_is_enum)(const void *);
    const void *(*class_enum_basetype)(void *);
    void *(*class_get_methods)(void *, void **);
    const char *(*method_get_name)(const void *);
    const void *(*method_get_return_type)(const void *);
    uint32_t (*method_get_param_count)(const void *);
    const void *(*method_get_param)(const void *, uint32_t);
    const char *(*method_get_param_name)(const void *, uint32_t);
    uint32_t (*method_get_flags)(const void *, uint32_t *);
    char *(*type_get_name)(const void *);
    bool (*type_is_byref)(const void *);
    const char *(*image_get_name)(const void *);
    uint32_t (*method_get_token)(const void *);
    void (*memory_free)(void *);
} ZA;

#define ZA_RESOLVE(a, n) (a)->n = (__typeof__((a)->n))dlsym(RTLD_DEFAULT, "il2cpp_" #n)

static bool za_resolve(ZA *a) {
    memset(a, 0, sizeof *a);
    ZA_RESOLVE(a, domain_get);
    ZA_RESOLVE(a, domain_get_assemblies);
    ZA_RESOLVE(a, assembly_get_image);
    ZA_RESOLVE(a, image_get_class_count);
    ZA_RESOLVE(a, image_get_class);
    ZA_RESOLVE(a, class_get_name);
    ZA_RESOLVE(a, class_get_namespace);
    ZA_RESOLVE(a, class_get_declaring_type);
    ZA_RESOLVE(a, class_get_type);
    ZA_RESOLVE(a, class_is_valuetype);
    ZA_RESOLVE(a, class_is_enum);
    ZA_RESOLVE(a, class_enum_basetype);
    ZA_RESOLVE(a, class_get_methods);
    ZA_RESOLVE(a, method_get_name);
    ZA_RESOLVE(a, method_get_return_type);
    ZA_RESOLVE(a, method_get_param_count);
    ZA_RESOLVE(a, method_get_param);
    ZA_RESOLVE(a, method_get_param_name);
    ZA_RESOLVE(a, method_get_flags);
    ZA_RESOLVE(a, type_get_name);
    ZA_RESOLVE(a, type_is_byref);
    ZA_RESOLVE(a, image_get_name);
    ZA_RESOLVE(a, method_get_token);
    a->memory_free = (void (*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_free");
    return a->domain_get && a->domain_get_assemblies && a->assembly_get_image && a->image_get_class_count && a->image_get_class &&
           a->class_get_name && a->class_get_namespace && a->class_get_methods && a->class_get_type && a->method_get_name &&
           a->method_get_return_type && a->method_get_param_count && a->method_get_param && a->method_get_flags;
}

typedef struct { char name[17]; uint64_t vmaddr, vmsize, fileoff, filesize; } ZSeg;
typedef struct { char seg[17]; char sect[17]; uint64_t addr, size; uint32_t flags; uint32_t offset; } ZSect;

typedef struct {
    uintptr_t header;
    intptr_t slide;
    uint64_t textVM;
    ZSeg segs[24];
    int nsegs;
    ZSect sects[128];
    int nsects;
    const uint8_t *file;
    size_t fileSize;
    size_t fileBase;
} ZImg;

static bool zi_load(ZImg *img, const void *base) {
    memset(img, 0, sizeof *img);
    const struct mach_header_64 *h = (const struct mach_header_64 *)base;
    if (h->magic != MH_MAGIC_64) return false;
    img->header = (uintptr_t)base;
    const uint8_t *cur = (const uint8_t *)(h + 1);
    bool haveText = false;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
            if (img->nsegs < 24) {
                ZSeg *s = &img->segs[img->nsegs++];
                memcpy(s->name, sc->segname, 16);
                s->name[16] = 0;
                s->vmaddr = sc->vmaddr; s->vmsize = sc->vmsize; s->fileoff = sc->fileoff; s->filesize = sc->filesize;
            }
            if (strncmp(sc->segname, "__TEXT", 16) == 0) { img->textVM = sc->vmaddr; haveText = true; }
            const struct section_64 *sec = (const struct section_64 *)(sc + 1);
            for (uint32_t k = 0; k < sc->nsects; k++) {
                if (img->nsects < 128) {
                    ZSect *s = &img->sects[img->nsects++];
                    memcpy(s->seg, sec[k].segname, 16); s->seg[16] = 0;
                    memcpy(s->sect, sec[k].sectname, 16); s->sect[16] = 0;
                    s->addr = sec[k].addr; s->size = sec[k].size; s->flags = sec[k].flags; s->offset = sec[k].offset;
                }
            }
        }
        cur += lc->cmdsize;
    }
    if (!haveText) return false;
    img->slide = (intptr_t)img->header - (intptr_t)img->textVM;
    return true;
}

static bool zi_file_open(ZImg *img, const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 4096) { close(fd); return false; }
    void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return false;
    img->file = (const uint8_t *)m;
    img->fileSize = (size_t)st.st_size;
    img->fileBase = 0;
    uint32_t magic;
    memcpy(&magic, img->file, 4);
    if (magic == 0xBEBAFECA) {
        uint32_t n = __builtin_bswap32(*(const uint32_t *)(img->file + 4));
        for (uint32_t i = 0; i < n && 8 + (i + 1) * 20 <= img->fileSize; i++) {
            const uint8_t *e = img->file + 8 + i * 20;
            uint32_t cpu = __builtin_bswap32(*(const uint32_t *)e);
            uint32_t off = __builtin_bswap32(*(const uint32_t *)(e + 8));
            if (cpu == 0x0100000C) { img->fileBase = off; break; }
        }
    }
    return true;
}

static void zi_file_close(ZImg *img) {
    if (img->file) munmap((void *)img->file, img->fileSize);
    img->file = NULL;
}

static bool zi_in_img(const ZImg *img, uint64_t addr, uint64_t len) {
    for (int i = 0; i < img->nsegs; i++) {
        uint64_t lo = (uint64_t)((int64_t)img->segs[i].vmaddr + img->slide);
        if (addr >= lo && addr + len <= lo + img->segs[i].vmsize) return true;
    }
    return false;
}

static bool zi_is_data_ptr(const ZImg *img, uint64_t addr) {
    if (addr & 7) return false;
    for (int i = 0; i < img->nsegs; i++) {
        if (strncmp(img->segs[i].name, "__DATA", 6) != 0) continue;
        uint64_t lo = (uint64_t)((int64_t)img->segs[i].vmaddr + img->slide);
        if (addr >= lo && addr + 8 <= lo + img->segs[i].vmsize) return true;
    }
    return false;
}

static bool zi_is_data_addr(const ZImg *img, uint64_t addr) {
    for (int i = 0; i < img->nsegs; i++) {
        if (strncmp(img->segs[i].name, "__DATA", 6) != 0) continue;
        uint64_t lo = (uint64_t)((int64_t)img->segs[i].vmaddr + img->slide);
        if (addr >= lo && addr + 4 <= lo + img->segs[i].vmsize) return true;
    }
    return false;
}

static bool zi_text_range(const ZImg *img, uint64_t *lo, uint64_t *hi) {
    for (int i = 0; i < img->nsects; i++) {
        if (strcmp(img->sects[i].seg, "__TEXT") == 0 && strcmp(img->sects[i].sect, "__text") == 0) {
            *lo = (uint64_t)((int64_t)img->sects[i].addr + img->slide);
            *hi = *lo + img->sects[i].size;
            return true;
        }
    }
    return false;
}

static bool zi_is_text_ptr(const ZImg *img, uint64_t p) {
    uint64_t lo, hi;
    return zi_text_range(img, &lo, &hi) && p >= lo && p < hi;
}

static bool zi_data_section(const ZImg *img, int k, const uint64_t **lo, const uint64_t **hi) {
    int seen = 0;
    for (int i = 0; i < img->nsects; i++) {
        const ZSect *s = &img->sects[i];
        if (strncmp(s->seg, "__DATA", 6) != 0) continue;
        uint32_t type = s->flags & 0xFF;
        if (type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL) continue;
        if (seen++ != k) continue;
        uint64_t a = (uint64_t)((int64_t)s->addr + img->slide);
        uint64_t b = a + s->size;
        a = (a + 7) & ~(uint64_t)7;
        b &= ~(uint64_t)7;
        if (b <= a) { *lo = *hi = NULL; return true; }
        *lo = (const uint64_t *)(uintptr_t)a;
        *hi = (const uint64_t *)(uintptr_t)b;
        return true;
    }
    return false;
}

static bool zi_file_u64(const ZImg *img, uint64_t rtAddr, uint64_t *out) {
    if (!img->file) return false;
    for (int i = 0; i < img->nsegs; i++) {
        const ZSeg *s = &img->segs[i];
        uint64_t lo = (uint64_t)((int64_t)s->vmaddr + img->slide);
        if (rtAddr < lo || rtAddr + 8 > lo + s->filesize) continue;
        uint64_t off = s->fileoff + (rtAddr - lo) + img->fileBase;
        if (off + 8 > img->fileSize) return false;
        memcpy(out, img->file + off, 8);
        return true;
    }
    return false;
}

static bool zc_rd(uint64_t addr, void *dst, size_t len) {
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr, (vm_size_t)len, (vm_address_t)dst, &got);
    return kr == KERN_SUCCESS && got == len;
}

static uint64_t zc_rd64(uint64_t addr) { uint64_t v = 0; zc_rd(addr, &v, 8); return v; }
static uint32_t zc_rd32(uint64_t addr) { uint32_t v = 0; zc_rd(addr, &v, 4); return v; }

typedef struct { uint64_t data; uint32_t bits; uint32_t pad; } ZType;

enum {
    ZT_VOID = 1, ZT_BOOLEAN, ZT_CHAR, ZT_I1, ZT_U1, ZT_I2, ZT_U2, ZT_I4, ZT_U4, ZT_I8, ZT_U8, ZT_R4, ZT_R8, ZT_STRING, ZT_PTR,
    ZT_BYREF, ZT_VALUETYPE, ZT_CLASS, ZT_VAR, ZT_ARRAY, ZT_GENERICINST, ZT_TYPEDBYREF, ZT_I = 24, ZT_U, ZT_FNPTR = 27, ZT_OBJECT,
    ZT_SZARRAY, ZT_MVAR
};

#define ZM_TD_SIZE 88

typedef struct {
    const uint8_t *p;
    size_t size;
    uint32_t version;
    uint32_t strLitOff, strLitSize, strDataOff, strDataSize;
    uint32_t strOff, strSize;
    uint32_t fieldsOff, fieldsSize;
    uint32_t gpOff, gpSize;
    uint32_t gcOff, gcSize;
    uint32_t tdOff, tdSize;
    uint32_t fieldRefOff, fieldRefSize;
    uint32_t strCountV;
    bool tables, v38;
} ZMeta;

static bool zm_range_ok(const ZMeta *m, uint32_t off, uint32_t size) {
    return (uint64_t)off + size <= m->size;
}

static bool zm_open(ZMeta *m, const char *path, void **mapping, size_t *mapSize) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 256) { close(fd); return false; }
    void *mp = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mp == MAP_FAILED) return false;
    *mapping = mp;
    *mapSize = (size_t)st.st_size;
    m->p = (const uint8_t *)mp;
    m->size = (size_t)st.st_size;
    uint32_t h[48];
    memcpy(h, m->p, sizeof h);
    if (h[0] != 0xFAB11BAF) return false;
    m->version = h[1];
    m->v38 = m->version >= 38;
    m->tables = false;
    if (m->v38) {
        m->strLitOff = h[2]; m->strLitSize = h[3]; m->strCountV = h[4];
        m->strDataOff = h[5]; m->strDataSize = h[6];
        if (m->strCountV == 0 || m->strLitSize / m->strCountV != 4) return false;
    } else {
        m->strLitOff = h[2]; m->strLitSize = h[3]; m->strDataOff = h[4]; m->strDataSize = h[5];
        m->strCountV = m->strLitSize / 8;
    }
    if ((uint64_t)m->strLitOff + m->strLitSize > m->size || (uint64_t)m->strDataOff + m->strDataSize > m->size) return false;
    if (m->version >= 27 && !m->v38) {
        m->strOff = h[6]; m->strSize = h[7];
        m->fieldsOff = h[24]; m->fieldsSize = h[25];
        m->gpOff = h[26]; m->gpSize = h[27];
        m->gcOff = h[30]; m->gcSize = h[31];
        m->tdOff = h[40]; m->tdSize = h[41];
        m->fieldRefOff = h[46]; m->fieldRefSize = h[47];
        m->tables = zm_range_ok(m, m->strOff, m->strSize) && zm_range_ok(m, m->fieldsOff, m->fieldsSize) &&
                    zm_range_ok(m, m->gpOff, m->gpSize) && zm_range_ok(m, m->gcOff, m->gcSize) &&
                    zm_range_ok(m, m->tdOff, m->tdSize) && zm_range_ok(m, m->fieldRefOff, m->fieldRefSize);
    }
    return true;
}

static uint32_t zm_string_count(const ZMeta *m) { return m->strCountV; }

static bool zm_string(const ZMeta *m, uint32_t idx, const uint8_t **bytes, uint32_t *len) {
    if (idx >= zm_string_count(m)) return false;
    if (m->v38) {
        uint32_t a = 0, b = 0;
        memcpy(&a, m->p + m->strLitOff + (size_t)idx * 4, 4);
        if (idx + 1 >= m->strCountV) { *bytes = m->p + m->strDataOff; *len = 0; return true; }
        memcpy(&b, m->p + m->strLitOff + (size_t)(idx + 1) * 4, 4);
        if (b < a || (uint64_t)b > m->strDataSize) return false;
        *bytes = m->p + m->strDataOff + a;
        *len = b - a;
        return true;
    }
    uint32_t e[2];
    memcpy(e, m->p + m->strLitOff + (size_t)idx * 8, 8);
    if ((uint64_t)e[1] + e[0] > m->strDataSize) return false;
    *bytes = m->p + m->strDataOff + e[1];
    *len = e[0];
    return true;
}

static uint32_t zm_rd32(const ZMeta *m, uint64_t off) {
    uint32_t v = 0;
    if (off + 4 <= m->size) memcpy(&v, m->p + off, 4);
    return v;
}

static uint32_t zm_rd16(const ZMeta *m, uint64_t off) {
    uint16_t v = 0;
    if (off + 2 <= m->size) memcpy(&v, m->p + off, 2);
    return v;
}

static const char *zm_cstr(const ZMeta *m, uint32_t idx) {
    if (!m->tables || idx >= m->strSize) return NULL;
    return (const char *)(m->p + m->strOff + idx);
}

static uint32_t zm_td_count(const ZMeta *m) { return m->tables ? m->tdSize / ZM_TD_SIZE : 0; }

static uint64_t zm_td_off(const ZMeta *m, uint32_t td) { return (uint64_t)m->tdOff + (uint64_t)td * ZM_TD_SIZE; }

static int32_t zm_td_container(const ZMeta *m, uint32_t td) { return (int32_t)zm_rd32(m, zm_td_off(m, td) + 24); }

static uint32_t zm_td_field_start(const ZMeta *m, uint32_t td) { return zm_rd32(m, zm_td_off(m, td) + 32); }

static uint32_t zm_td_method_start(const ZMeta *m, uint32_t td) { return zm_rd32(m, zm_td_off(m, td) + 36); }

static uint32_t zm_td_method_count(const ZMeta *m, uint32_t td) { return zm_rd16(m, zm_td_off(m, td) + 64); }

static void zm_container_params(const ZMeta *m, int32_t gci, ZB *out) {
    if (gci < 0 || (uint64_t)(gci + 1) * 16 > m->gcSize) return;
    uint64_t g = (uint64_t)m->gcOff + (uint64_t)gci * 16;
    uint32_t argc = zm_rd32(m, g + 4), start = zm_rd32(m, g + 12);
    if (argc == 0 || argc > 64) return;
    zb_putc(out, '<');
    for (uint32_t i = 0; i < argc; i++) {
        if (i) zb_puts(out, ", ");
        uint64_t pi = (uint64_t)start + i;
        const char *n = (pi + 1) * 16 <= m->gpSize ? zm_cstr(m, zm_rd32(m, (uint64_t)m->gpOff + pi * 16 + 4)) : NULL;
        zb_puts(out, n ? n : "T");
    }
    zb_putc(out, '>');
}

static bool zm_gp_num(const ZMeta *m, uint64_t index, uint32_t *num) {
    if (!m->tables || (index + 1) * 16 > m->gpSize) return false;
    *num = zm_rd16(m, (uint64_t)m->gpOff + index * 16 + 12);
    return true;
}

static uint32_t zm_field_ref_count(const ZMeta *m) { return m->tables ? m->fieldRefSize / 8 : 0; }

static bool zm_field_ref(const ZMeta *m, uint32_t idx, uint32_t *typeIndex, uint32_t *fieldIndex) {
    if (idx >= zm_field_ref_count(m)) return false;
    uint64_t o = (uint64_t)m->fieldRefOff + (uint64_t)idx * 8;
    *typeIndex = zm_rd32(m, o);
    *fieldIndex = zm_rd32(m, o + 4);
    return true;
}

static const char *zm_field_name(const ZMeta *m, uint64_t fieldDefIndex) {
    if (!m->tables || (fieldDefIndex + 1) * 12 > m->fieldsSize) return NULL;
    return zm_cstr(m, zm_rd32(m, (uint64_t)m->fieldsOff + fieldDefIndex * 12));
}

typedef struct {
    ZA a;
    ZImg *img;
    const ZMeta *meta;
    bool tdMap;
    bool byrefBit29;
    void **cls;
    uint32_t td;
    bool handleMode;
    uint64_t h0, stride;
    char **nameNs;
    char **nameNoNs;
    char **structBase;
    char **structName;
    uint32_t *clsMethodStart;
    uint32_t *clsAsm;
    char **asmName;
    uint32_t asmCount;
    uint32_t defCount;
    const void **defMethod;
    uint32_t *defClass;
    uint64_t *defRva;
} ZC;

typedef struct {
    uint64_t cls, mth;
    bool has;
} ZCtx;

static const char *zc_prim_cs(int t) {
    switch (t) {
        case ZT_VOID: return "void";
        case ZT_BOOLEAN: return "bool";
        case ZT_CHAR: return "char";
        case ZT_I1: return "sbyte";
        case ZT_U1: return "byte";
        case ZT_I2: return "short";
        case ZT_U2: return "ushort";
        case ZT_I4: return "int";
        case ZT_U4: return "uint";
        case ZT_I8: return "long";
        case ZT_U8: return "ulong";
        case ZT_R4: return "float";
        case ZT_R8: return "double";
        case ZT_STRING: return "string";
        case ZT_OBJECT: return "object";
        case ZT_I: return "IntPtr";
        case ZT_U: return "UIntPtr";
        case ZT_FNPTR: return "IntPtr";
        case ZT_TYPEDBYREF: return "TypedReference";
        default: return NULL;
    }
}

static const char *zc_prim_struct(int t) {
    switch (t) {
        case ZT_VOID: return "System_Void";
        case ZT_BOOLEAN: return "System_Boolean";
        case ZT_CHAR: return "System_Char";
        case ZT_I1: return "System_SByte";
        case ZT_U1: return "System_Byte";
        case ZT_I2: return "System_Int16";
        case ZT_U2: return "System_UInt16";
        case ZT_I4: return "System_Int32";
        case ZT_U4: return "System_UInt32";
        case ZT_I8: return "System_Int64";
        case ZT_U8: return "System_UInt64";
        case ZT_R4: return "System_Single";
        case ZT_R8: return "System_Double";
        case ZT_STRING: return "System_String";
        case ZT_OBJECT: return "System_Object";
        case ZT_I: return "System_IntPtr";
        case ZT_U: return "System_UIntPtr";
        case ZT_TYPEDBYREF: return "System_TypedReference";
        default: return "System_Object";
    }
}

static void zc_build_typedef(ZC *c, void *k, bool ns, ZB *t) {
    void *decl = c->a.class_get_declaring_type ? c->a.class_get_declaring_type(k) : NULL;
    if (decl && decl != k) {
        zc_build_typedef(c, decl, ns, t);
        zb_putc(t, '.');
    } else if (ns) {
        const char *n = c->a.class_get_namespace(k);
        if (n && *n) { zb_puts(t, n); zb_putc(t, '.'); }
    }
    const char *name = c->a.class_get_name(k);
    if (!name) return;
    const char *tick = strchr(name, '`');
    zb_putn(t, name, tick ? (size_t)(tick - name) : strlen(name));
}

static void zc_typedef_name(ZC *c, uint32_t idx, bool ns, ZB *out) {
    if (idx >= c->td) { zb_puts(out, "?"); return; }
    char **cache = ns ? c->nameNs : c->nameNoNs;
    if (!cache[idx]) {
        ZB t;
        zb_init(&t);
        zc_build_typedef(c, c->cls[idx], ns, &t);
        cache[idx] = strdup(t.p ? t.p : "");
        zb_free(&t);
    }
    zb_puts(out, cache[idx]);
}

static void zc_typedef_name_gp(ZC *c, uint32_t idx, bool ns, ZB *out) {
    zc_typedef_name(c, idx, ns, out);
    if (c->tdMap && idx < c->td) zm_container_params(c->meta, zm_td_container(c->meta, idx), out);
}

static bool zc_td_from_data(ZC *c, uint64_t data, uint32_t *idx) {
    if (!c->handleMode) {
        if (data >= c->td) return false;
        *idx = (uint32_t)data;
        return true;
    }
    if (data < c->h0 || c->stride == 0) return false;
    uint64_t d = data - c->h0;
    if (d % c->stride) return false;
    d /= c->stride;
    if (d >= c->td) return false;
    *idx = (uint32_t)d;
    return true;
}

static bool zc_gc_td(ZC *c, uint64_t gc, uint32_t *idx) {
    uint64_t v = zc_rd64(gc);
    if (zc_td_from_data(c, v, idx)) return true;
    ZType t;
    if (v && zc_rd(v, &t, sizeof t)) {
        int ty = (int)((t.bits >> 16) & 0xFF);
        if ((ty == ZT_CLASS || ty == ZT_VALUETYPE) && zc_td_from_data(c, t.data, idx)) return true;
    }
    return false;
}

static bool zc_type_byref(const ZC *c, uint64_t tptr, const ZType *t) {
    if (c->a.type_is_byref) return c->a.type_is_byref((const void *)(uintptr_t)tptr);
    return ((t->bits >> (c->byrefBit29 ? 29 : 30)) & 1) != 0;
}

static void zc_type_name(ZC *c, uint64_t tptr, bool ns, int depth, ZB *out);

static void zc_inst_args(ZC *c, uint64_t inst, int depth, ZB *out) {
    if (!inst) return;
    uint32_t argc = zc_rd32(inst);
    uint64_t argv = zc_rd64(inst + 8);
    if (argc == 0 || argc > 64 || !argv) return;
    zb_putc(out, '<');
    for (uint32_t i = 0; i < argc; i++) {
        if (i) zb_puts(out, ", ");
        zc_type_name(c, zc_rd64(argv + 8ull * i), false, depth + 1, out);
    }
    zb_putc(out, '>');
}

static void zc_type_name(ZC *c, uint64_t tptr, bool ns, int depth, ZB *out) {
    ZType t;
    if (depth > 12 || !tptr || !zc_rd(tptr, &t, sizeof t)) { zb_puts(out, "?"); return; }
    int ty = (int)((t.bits >> 16) & 0xFF);
    const char *prim = zc_prim_cs(ty);
    if (prim) { zb_puts(out, prim); return; }
    uint32_t idx;
    switch (ty) {
        case ZT_PTR:
            zc_type_name(c, t.data, ns, depth + 1, out);
            zb_putc(out, '*');
            return;
        case ZT_SZARRAY:
            zc_type_name(c, t.data, ns, depth + 1, out);
            zb_puts(out, "[]");
            return;
        case ZT_ARRAY: {
            uint8_t rank = 1;
            zc_rd(t.data + 8, &rank, 1);
            zc_type_name(c, zc_rd64(t.data), ns, depth + 1, out);
            zb_putc(out, '[');
            for (uint8_t i = 1; i < rank; i++) zb_putc(out, ',');
            zb_putc(out, ']');
            return;
        }
        case ZT_CLASS:
        case ZT_VALUETYPE:
            if (zc_td_from_data(c, t.data, &idx)) zc_typedef_name_gp(c, idx, ns, out);
            else zb_puts(out, "?");
            return;
        case ZT_GENERICINST: {
            uint64_t gc = t.data;
            if (zc_gc_td(c, gc, &idx)) zc_typedef_name(c, idx, ns, out);
            else zb_puts(out, "?");
            zc_inst_args(c, zc_rd64(gc + 8), depth, out);
            return;
        }
        default: {
            char *n = c->a.type_get_name ? c->a.type_get_name((const void *)(uintptr_t)tptr) : NULL;
            if (n) {
                zb_puts(out, n);
                if (c->a.memory_free) c->a.memory_free(n);
            } else {
                zb_puts(out, "T");
            }
            return;
        }
    }
}

static void zc_fix(ZB *b, size_t from) {
    size_t w = from;
    for (size_t i = from; i < b->n;) {
        unsigned char ch = (unsigned char)b->p[i];
        if (ch < 0x80) {
            bool ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_';
            b->p[w++] = ok ? (char)ch : '_';
            i++;
            continue;
        }
        size_t len = 1;
        int units = 1;
        if (ch >= 0xC2 && ch <= 0xDF) len = 2;
        else if (ch >= 0xE0 && ch <= 0xEF) len = 3;
        else if (ch >= 0xF0 && ch <= 0xF4) { len = 4; units = 2; }
        if (i + len > b->n) { len = 1; units = 1; }
        for (int u = 0; u < units; u++) b->p[w++] = '_';
        i += len;
    }
    b->n = w;
    if (b->p) b->p[w] = 0;
}

static bool zc_name_in(const char *s, const char *const *list, size_t n) {
    for (size_t i = 0; i < n; i++) if (strcmp(s, list[i]) == 0) return true;
    return false;
}

static void zc_fixname(const char *s, ZB *out) {
    static const char *const kw[] = {"klass", "monitor", "register", "_cs", "auto", "friend", "template", "flat", "default", "_ds", "interrupt",
        "unsigned", "signed", "asm", "if", "case", "break", "continue", "do", "new", "_", "short", "union", "class", "namespace"};
    static const char *const sp[] = {"inline", "near", "far"};
    size_t from = out->n;
    if (zc_name_in(s, kw, sizeof kw / sizeof kw[0])) {
        zb_putc(out, '_');
        zb_puts(out, s);
    } else if (zc_name_in(s, sp, sizeof sp / sizeof sp[0])) {
        zb_putc(out, '_');
        zb_puts(out, s);
        zb_putc(out, '_');
    } else {
        if (s[0] >= '0' && s[0] <= '9') zb_putc(out, '_');
        zb_puts(out, s);
    }
    zc_fix(out, from);
}

typedef struct {
    char **keys;
    size_t cap;
} ZStrSet;

static bool zss_init(ZStrSet *s, size_t want) {
    size_t cap = 1024;
    while (cap < want * 2) cap *= 2;
    s->keys = (char **)calloc(cap, sizeof(char *));
    s->cap = cap;
    return s->keys != NULL;
}

static bool zss_add(ZStrSet *s, const char *key) {
    uint64_t h = 1469598103934665603ull;
    for (const unsigned char *p = (const unsigned char *)key; *p; p++) { h ^= *p; h *= 1099511628211ull; }
    size_t i = (size_t)h & (s->cap - 1);
    while (s->keys[i]) {
        if (strcmp(s->keys[i], key) == 0) return false;
        i = (i + 1) & (s->cap - 1);
    }
    s->keys[i] = strdup(key);
    return true;
}

static void zss_free(ZStrSet *s) {
    if (s->keys) for (size_t i = 0; i < s->cap; i++) free(s->keys[i]);
    free(s->keys);
    s->keys = NULL;
}

static void zc_build_struct_names(ZC *c) {
    c->structBase = (char **)calloc(c->td + 1, sizeof(char *));
    c->structName = (char **)calloc(c->td + 1, sizeof(char *));
    ZStrSet set;
    if (!c->structBase || !c->structName || !zss_init(&set, (size_t)c->td + 16)) return;
    ZB t, f, u;
    zb_init(&t); zb_init(&f); zb_init(&u);
    for (uint32_t i = 0; i < c->td; i++) {
        zb_reset(&t); zb_reset(&f);
        zc_typedef_name_gp(c, i, true, &t);
        zc_fixname(t.p ? t.p : "", &f);
        const char *base = f.p ? f.p : "";
        c->structBase[i] = strdup(base);
        if (zss_add(&set, base)) {
            c->structName[i] = strdup(base);
            continue;
        }
        for (int k = 1;; k++) {
            zb_reset(&u);
            zb_printf(&u, "%s_%d", base, k);
            if (zss_add(&set, u.p)) { c->structName[i] = strdup(u.p); break; }
        }
    }
    zb_free(&t); zb_free(&f); zb_free(&u);
    zss_free(&set);
}

static void zc_replace_into(const char *s, const char *from, const char *to, ZB *out) {
    size_t fl = strlen(from);
    if (!fl) { zb_puts(out, s); return; }
    const char *p = s, *q;
    while ((q = strstr(p, from))) {
        zb_putn(out, p, (size_t)(q - p));
        zb_puts(out, to);
        p = q + fl;
    }
    zb_puts(out, p);
}

static bool zc_ctx_arg(ZC *c, uint64_t inst, uint32_t num, uint64_t *tptr) {
    if (!inst) return false;
    uint32_t argc = zc_rd32(inst);
    uint64_t argv = zc_rd64(inst + 8);
    if (num >= argc || argc > 64 || !argv) return false;
    *tptr = zc_rd64(argv + 8ull * num);
    (void)c;
    return *tptr != 0;
}

static bool zc_gp_num(ZC *c, const ZType *t, uint32_t *num) {
    if (t->data >= 0x100000) {
        uint16_t v;
        if (!zc_rd(t->data + 12, &v, 2)) return false;
        *num = v;
        return true;
    }
    return c->meta ? zm_gp_num(c->meta, t->data, num) : false;
}

static bool zc_resolve_var(ZC *c, const ZType *t, int ty, const ZCtx *ctx, uint64_t *out) {
    if (!ctx || !ctx->has) return false;
    uint32_t num;
    if (!zc_gp_num(c, t, &num)) return false;
    uint64_t inst = ctx->cls;
    if (ty == ZT_MVAR && !(ctx->mth == 0 && ctx->cls != 0)) inst = ctx->mth;
    return zc_ctx_arg(c, inst, num, out);
}

static bool zc_resolve_var_struct(ZC *c, const ZType *t, int ty, const ZCtx *ctx, uint64_t *out) {
    if (!ctx || !ctx->has) return false;
    uint32_t num;
    if (!zc_gp_num(c, t, &num)) return false;
    return zc_ctx_arg(c, ty == ZT_MVAR ? ctx->mth : ctx->cls, num, out);
}

static void zc_struct_name(ZC *c, uint64_t tptr, const ZCtx *ctx, int depth, ZB *out);

static void zc_generic_struct_name(ZC *c, uint64_t tptr, uint64_t gc, ZB *out) {
    uint32_t idx;
    if (!zc_gc_td(c, gc, &idx) || !c->structName || !c->structName[idx]) { zb_puts(out, "System_Object"); return; }
    ZB inst, fixed;
    zb_init(&inst); zb_init(&fixed);
    zc_type_name(c, tptr, true, 0, &inst);
    zc_fixname(inst.p ? inst.p : "", &fixed);
    zc_replace_into(c->structName[idx], c->structBase[idx], fixed.p ? fixed.p : "", out);
    zb_free(&inst); zb_free(&fixed);
}

static void zc_struct_name(ZC *c, uint64_t tptr, const ZCtx *ctx, int depth, ZB *out) {
    ZType t;
    if (depth > 8 || !tptr || !zc_rd(tptr, &t, sizeof t)) { zb_puts(out, "System_Object"); return; }
    int ty = (int)((t.bits >> 16) & 0xFF);
    uint32_t idx;
    uint64_t arg;
    switch (ty) {
        case ZT_PTR:
            zc_struct_name(c, t.data, NULL, depth + 1, out);
            return;
        case ZT_SZARRAY:
            zc_struct_name(c, t.data, ctx, depth + 1, out);
            zb_puts(out, "_array");
            return;
        case ZT_ARRAY:
            zc_struct_name(c, zc_rd64(t.data), ctx, depth + 1, out);
            zb_puts(out, "_array");
            return;
        case ZT_GENERICINST:
            zc_generic_struct_name(c, tptr, t.data, out);
            return;
        case ZT_VAR:
        case ZT_MVAR:
            if (zc_resolve_var_struct(c, &t, ty, ctx, &arg)) zc_struct_name(c, arg, NULL, depth + 1, out);
            else zb_puts(out, "System_Object");
            return;
        case ZT_CLASS:
        case ZT_VALUETYPE:
        default:
            if (zc_td_from_data(c, t.data, &idx) && c->structName && c->structName[idx]) zb_puts(out, c->structName[idx]);
            else zb_puts(out, zc_prim_struct(ty));
            return;
    }
}

static bool zc_enum_underlying(ZC *c, uint32_t idx, uint64_t *base) {
    if (idx >= c->td || !c->a.class_is_enum || !c->a.class_enum_basetype) return false;
    if (!c->a.class_is_enum(c->cls[idx])) return false;
    const void *bt = c->a.class_enum_basetype(c->cls[idx]);
    if (!bt) return false;
    *base = (uint64_t)(uintptr_t)bt;
    return true;
}

static void zc_ctype(ZC *c, uint64_t tptr, const ZCtx *ctx, int depth, ZB *out) {
    ZType t;
    if (depth > 8 || !tptr || !zc_rd(tptr, &t, sizeof t)) { zb_puts(out, "Il2CppObject*"); return; }
    int ty = (int)((t.bits >> 16) & 0xFF);
    uint32_t idx;
    uint64_t arg;
    switch (ty) {
        case ZT_VOID: zb_puts(out, "void"); break;
        case ZT_BOOLEAN: zb_puts(out, "bool"); break;
        case ZT_CHAR: zb_puts(out, "uint16_t"); break;
        case ZT_I1: zb_puts(out, "int8_t"); break;
        case ZT_U1: zb_puts(out, "uint8_t"); break;
        case ZT_I2: zb_puts(out, "int16_t"); break;
        case ZT_U2: zb_puts(out, "uint16_t"); break;
        case ZT_I4: zb_puts(out, "int32_t"); break;
        case ZT_U4: zb_puts(out, "uint32_t"); break;
        case ZT_I8: zb_puts(out, "int64_t"); break;
        case ZT_U8: zb_puts(out, "uint64_t"); break;
        case ZT_R4: zb_puts(out, "float"); break;
        case ZT_R8: zb_puts(out, "double"); break;
        case ZT_I: zb_puts(out, "intptr_t"); break;
        case ZT_U: zb_puts(out, "uintptr_t"); break;
        case ZT_OBJECT:
        case ZT_TYPEDBYREF: zb_puts(out, "Il2CppObject*"); break;
        case ZT_STRING: zb_puts(out, "System_String_o*"); break;
        case ZT_PTR:
            zc_ctype(c, t.data, NULL, depth + 1, out);
            zb_putc(out, '*');
            break;
        case ZT_FNPTR: zb_puts(out, "void*"); break;
        case ZT_SZARRAY:
        case ZT_ARRAY:
            zc_struct_name(c, tptr, ctx, depth + 1, out);
            zb_putc(out, '*');
            break;
        case ZT_CLASS:
        case ZT_VALUETYPE:
            if (!zc_td_from_data(c, t.data, &idx) || !c->structName || !c->structName[idx]) { zb_puts(out, "Il2CppObject*"); break; }
            if (ty == ZT_VALUETYPE) {
                if (zc_enum_underlying(c, idx, &arg)) { zc_ctype(c, arg, NULL, depth + 1, out); break; }
                zb_puts(out, c->structName[idx]);
                zb_puts(out, "_o");
            } else {
                zb_puts(out, c->structName[idx]);
                zb_puts(out, "_o*");
            }
            break;
        case ZT_GENERICINST: {
            if (!zc_gc_td(c, t.data, &idx)) { zb_puts(out, "Il2CppObject*"); break; }
            bool valueType = c->a.class_is_valuetype && c->a.class_is_valuetype(c->cls[idx]);
            if (valueType && zc_enum_underlying(c, idx, &arg)) { zc_ctype(c, arg, NULL, depth + 1, out); break; }
            zc_generic_struct_name(c, tptr, t.data, out);
            zb_puts(out, valueType ? "_o" : "_o*");
            break;
        }
        case ZT_VAR:
        case ZT_MVAR:
            if (zc_resolve_var(c, &t, ty, ctx, &arg)) zc_ctype(c, arg, NULL, depth + 1, out);
            else zb_puts(out, "Il2CppObject*");
            break;
        default:
            zb_puts(out, "Il2CppObject*");
            break;
    }
}

static void zc_ctype_sig(ZC *c, uint64_t tptr, const ZCtx *ctx, ZB *out) {
    ZType t;
    zc_ctype(c, tptr, ctx, 0, out);
    if (tptr && zc_rd(tptr, &t, sizeof t) && zc_type_byref(c, tptr, &t)) zb_putc(out, '*');
}

static char zc_tchar(ZC *c, uint64_t tptr) {
    ZType t;
    if (!tptr || !zc_rd(tptr, &t, sizeof t)) return 'i';
    if (zc_type_byref(c, tptr, &t)) return 'i';
    switch ((int)((t.bits >> 16) & 0xFF)) {
        case ZT_VOID: return 'v';
        case ZT_I8: case ZT_U8: return 'j';
        case ZT_R4: return 'f';
        case ZT_R8: return 'd';
        default: return 'i';
    }
}

typedef struct {
    uint64_t genericInsts, types, gmt, specs, usages;
    uint32_t nGenericInsts, nTypes, nGmt, nSpecs;
    uint64_t nUsages;
    uint32_t gmtStride;
    uint64_t gmp, adj, invoker, revp;
    uint32_t nGmp, nInvoker, nRevp;
    uint64_t unresolved, cgm, crAddr;
    uint32_t nUnresolved, nCgm, candidates;
    bool haveMR, haveCR, crHasAdj, haveCGM;
} ZR;

static bool zr_ptr_array_ok(const ZImg *img, uint64_t addr, uint64_t count, bool needText) {
    if (!addr || count == 0 || count > 20000000) return false;
    if (!zi_in_img(img, addr, count * 8)) return false;
    uint64_t sample = count < 128 ? count : 128;
    uint64_t good = 0;
    for (uint64_t i = 0; i < sample; i++) {
        uint64_t a = zc_rd64(addr + 8 * i);
        uint64_t b = zc_rd64(addr + 8 * (count - 1 - i));
        if (a == 0 || (needText ? zi_is_text_ptr(img, a) : zi_in_img(img, a, 1))) good++;
        if (b == 0 || (needText ? zi_is_text_ptr(img, b) : zi_in_img(img, b, 1))) good++;
    }
    return good == sample * 2;
}

static bool zr_find_metadata_registration(const ZImg *img, uint32_t td, ZR *r) {
    const uint64_t *lo, *hi;
    for (int k = 0; zi_data_section(img, k, &lo, &hi); k++) {
        if (!lo) continue;
        for (const uint64_t *q = lo + 12; q + 4 <= hi; q++) {
            if (*q != td) continue;
            if (!zi_is_data_addr(img, q[1])) continue;
            if (q[2] > 0x4000000) continue;
            if (q[2] && !zi_is_data_addr(img, q[3])) continue;
            const uint64_t *s = q - 12;
            bool ok = true;
            for (int i = 0; i < 12 && ok; i += 2) {
                if (s[i] == 0 || s[i] > 0x4000000 || !zi_is_data_addr(img, s[i + 1])) ok = false;
            }
            if (!ok || s[6] < td) continue;
            if (!zr_ptr_array_ok(img, s[7], s[6] < 64 ? s[6] : 64, false)) continue;
            r->nGenericInsts = (uint32_t)s[2]; r->genericInsts = s[3];
            r->nGmt = (uint32_t)s[4]; r->gmt = s[5];
            r->nTypes = (uint32_t)s[6]; r->types = s[7];
            r->nSpecs = (uint32_t)s[8]; r->specs = s[9];
            r->nUsages = q[2]; r->usages = q[3];
            r->haveMR = true;
            return true;
        }
    }
    for (int k = 0; zi_data_section(img, k, &lo, &hi); k++) {
        if (!lo) continue;
        for (const uint64_t *q = lo + 10; q + 4 <= hi; q++) {
            if (q[0] != td || q[2] != td) continue;
            if (!zi_is_data_addr(img, q[3]) || !zr_ptr_array_ok(img, q[3], td < 64 ? td : 64, false)) continue;
            r->candidates++;
            const uint64_t *b = q - 10;
            if (b[6] < td || b[6] > 0x4000000 || !zr_ptr_array_ok(img, b[7], b[6] < 64 ? b[6] : 64, false)) continue;
            if (!zi_in_img(img, b[3], 8) || !zi_in_img(img, b[5], 4) || !zi_in_img(img, b[9], 4)) continue;
            r->nGenericInsts = (uint32_t)b[2]; r->genericInsts = b[3];
            r->nGmt = (uint32_t)b[4]; r->gmt = b[5];
            r->nTypes = (uint32_t)b[6]; r->types = b[7];
            r->nSpecs = (uint32_t)b[8]; r->specs = b[9];
            r->nUsages = b[14]; r->usages = b[15];
            r->haveMR = true;
            return true;
        }
    }
    return false;
}

static bool zr_detect_gmt_stride(const ZImg *img, ZR *r) {
    static const uint32_t strides[2] = {16, 12};
    for (int si = 0; si < 2; si++) {
        uint32_t st = strides[si];
        uint32_t n = r->nGmt < 64 ? r->nGmt : 64;
        if (n < 2 || !zi_in_img(img, r->gmt, (uint64_t)r->nGmt * st)) continue;
        bool ok = true;
        int64_t prev = -1;
        for (uint32_t i = 0; i < n && ok; i++) {
            uint32_t e[2];
            if (!zc_rd(r->gmt + (uint64_t)i * st, e, 8)) { ok = false; break; }
            if (e[0] >= r->nSpecs || (int64_t)e[0] < prev || e[1] > 20000000) ok = false;
            prev = e[0];
        }
        if (ok) { r->gmtStride = st; return true; }
    }
    return false;
}

static bool zr_find_code_registration(const ZImg *img, ZR *r, uint32_t maxMethodIndex) {
    const uint64_t *lo, *hi;
    for (int k = 0; zi_data_section(img, k, &lo, &hi); k++) {
        if (!lo) continue;
        for (const uint64_t *q = lo + 2; q + 5 <= hi; q++) {
            uint64_t C = *q;
            if (C <= maxMethodIndex || C > (uint64_t)maxMethodIndex + 4000000ull) continue;
            if (!zi_is_data_ptr(img, q[1])) continue;
            if (!zr_ptr_array_ok(img, q[1], C, true)) continue;
            bool variantA = zi_is_data_ptr(img, q[2]) && zr_ptr_array_ok(img, q[2], C < 64 ? C : 64, true) &&
                            q[3] > 0 && q[3] < 20000000 && zi_is_data_ptr(img, q[4]) && zr_ptr_array_ok(img, q[4], q[3], true);
            bool variantB = !variantA && q[2] > 0 && q[2] < 20000000 && zi_is_data_ptr(img, q[3]) && zr_ptr_array_ok(img, q[3], q[2], true);
            if (!variantA && !variantB) continue;
            r->gmp = q[1];
            r->nGmp = (uint32_t)C;
            if (variantA) { r->adj = q[2]; r->nInvoker = (uint32_t)q[3]; r->invoker = q[4]; }
            else { r->adj = 0; r->nInvoker = (uint32_t)q[2]; r->invoker = q[3]; }
            if (q - 2 >= lo && q[-2] > 0 && q[-2] < 1000000 && zi_is_data_ptr(img, q[-1]) && zr_ptr_array_ok(img, q[-1], q[-2], true)) {
                r->nRevp = (uint32_t)q[-2];
                r->revp = q[-1];
            }
            r->haveCR = true;
            r->crAddr = (uint64_t)(uintptr_t)q;
            r->crHasAdj = variantA;
            return true;
        }
    }
    return false;
}

static bool zr_valid_modules(const ZImg *img, uint64_t arr, uint64_t count) {
    if (!arr || count == 0 || count > 4096 || !zi_in_img(img, arr, count * 8)) return false;
    uint64_t n = count < 8 ? count : 8;
    for (uint64_t i = 0; i < n; i++) {
        uint64_t m = zc_rd64(arr + 8 * i);
        if (!m || !zi_in_img(img, m, 24)) return false;
        uint64_t name = zc_rd64(m);
        unsigned char nb[3] = {0, 0, 0};
        if (!name || !zc_rd(name, nb, 3)) return false;
        for (int k = 0; k < 3; k++) if (nb[k] < 0x20 || nb[k] > 0x7e) return false;
        uint64_t mc = zc_rd64(m + 8), mp = zc_rd64(m + 16);
        if (mc > 4000000 || (mc && !zi_in_img(img, mp, mc * 8))) return false;
    }
    return true;
}

static size_t zr_refs(const ZImg *img, uint64_t target, uint64_t lowTarget, uint64_t *out, size_t cap, uint64_t countAt) {
    size_t n = 0;
    const uint64_t *lo, *hi;
    for (int k = 0; zi_data_section(img, k, &lo, &hi); k++) {
        if (!lo) continue;
        for (const uint64_t *q = lo; q < hi; q++) {
            uint64_t v = *q;
            if (v > target || v < lowTarget) continue;
            if ((target - v) & 7) continue;
            if (countAt && (q == lo || q[-1] != countAt)) continue;
            if (n < cap) out[n] = (uint64_t)(uintptr_t)q;
            n++;
        }
    }
    return n < cap ? n : cap;
}

static bool zr_find_code_registration_modules(const ZImg *img, uint32_t imageCount, ZR *r) {
    static const char key[] = "mscorlib.dll";
    for (int si = 0; si < img->nsects; si++) {
        const ZSect *sc = &img->sects[si];
        if (strcmp(sc->sect, "__cstring") != 0) continue;
        const char *base = (const char *)(uintptr_t)((int64_t)sc->addr + img->slide);
        for (uint64_t off = 0; off + sizeof key <= sc->size; off++) {
            if (memcmp(base + off, key, sizeof key) != 0) continue;
            uint64_t str = (uint64_t)(uintptr_t)(base + off);
            uint64_t r1[8], r2[8], r3[64];
            size_t n1 = zr_refs(img, str, str, r1, 8, 0);
            for (size_t a = 0; a < n1; a++) {
                size_t n2 = zr_refs(img, r1[a], r1[a], r2, 8, 0);
                for (size_t b = 0; b < n2; b++) {
                    for (uint32_t delta = 0; delta <= 3; delta++) {
                        for (int sign = 0; sign < 2; sign++) {
                            if (delta == 0 && sign) continue;
                            uint32_t cnt = sign ? imageCount + delta : imageCount - delta;
                            if (!cnt || (!sign && delta > imageCount)) continue;
                            uint64_t low = r2[b] >= 8ull * (cnt - 1) ? r2[b] - 8ull * (cnt - 1) : 0;
                            size_t n3 = zr_refs(img, r2[b], low, r3, 64, cnt);
                            for (size_t c3 = 0; c3 < n3; c3++) {
                                uint64_t at = r3[c3];
                                uint64_t crBase = at - 8 * 16;
                                if (!zi_in_img(img, crBase, 8 * 17)) continue;
                                uint64_t arr = zc_rd64(at);
                                if (!zr_valid_modules(img, arr, cnt)) continue;
                                r->crAddr = crBase;
                                r->nRevp = (uint32_t)zc_rd64(crBase); r->revp = zc_rd64(crBase + 8);
                                r->nGmp = (uint32_t)zc_rd64(crBase + 16); r->gmp = zc_rd64(crBase + 24);
                                r->adj = zc_rd64(crBase + 32);
                                r->nInvoker = (uint32_t)zc_rd64(crBase + 40); r->invoker = zc_rd64(crBase + 48);
                                r->nUnresolved = (uint32_t)zc_rd64(crBase + 56); r->unresolved = zc_rd64(crBase + 64);
                                r->nCgm = cnt; r->cgm = arr;
                                r->haveCR = true; r->haveCGM = true; r->crHasAdj = true;
                                if (r->nRevp > 1000000 || !zr_ptr_array_ok(img, r->revp, r->nRevp < 64 ? r->nRevp : 64, true)) { r->nRevp = 0; r->revp = 0; }
                                if (r->nUnresolved > 1000000 || !zr_ptr_array_ok(img, r->unresolved, r->nUnresolved < 64 ? r->nUnresolved : 64, true)) { r->nUnresolved = 0; r->unresolved = 0; }
                                if (r->nGmp > 20000000 || !zr_ptr_array_ok(img, r->gmp, r->nGmp < 64 ? r->nGmp : 64, true)) { r->nGmp = 0; r->gmp = 0; }
                                return true;
                            }
                        }
                    }
                }
            }
        }
    }
    return false;
}

static void zr_find_modules(const ZImg *img, ZR *r) {
    if (!r->haveCR || !r->crAddr) return;
    uint64_t q = r->crAddr;
    uint64_t first = r->crHasAdj ? 5 : 4;
    uint64_t uc = zc_rd64(q + 8 * first), up = zc_rd64(q + 8 * (first + 1));
    if (uc > 0 && uc < 1000000 && zr_ptr_array_ok(img, up, uc, true)) { r->nUnresolved = (uint32_t)uc; r->unresolved = up; }
    static const uint64_t extras[2] = {0, 2};
    for (int e = 0; e < 2; e++) {
        uint64_t at = first + 2 + extras[e] + 4;
        uint64_t count = zc_rd64(q + 8 * at), arr = zc_rd64(q + 8 * (at + 1));
        if (zr_valid_modules(img, arr, count)) {
            r->nCgm = (uint32_t)count;
            r->cgm = arr;
            r->haveCGM = true;
            return;
        }
    }
}

typedef struct {
    uint64_t *v;
    size_t n, cap;
} ZU64;

static void zu_push(ZU64 *a, uint64_t x) {
    if (a->n == a->cap) {
        size_t cap = a->cap ? a->cap * 2 : 4096;
        uint64_t *p = (uint64_t *)realloc(a->v, cap * 8);
        if (!p) return;
        a->v = p; a->cap = cap;
    }
    a->v[a->n++] = x;
}

static int zu_cmp(const void *x, const void *y) {
    uint64_t a = *(const uint64_t *)x, b = *(const uint64_t *)y;
    return a < b ? -1 : (a > b ? 1 : 0);
}

typedef struct {
    void *ud;
    void (*progress)(void *ud, const char *stage, double fraction);
    void (*log)(void *ud, const char *line);
    bool (*cancelled)(void *ud);
} ZHooks;

static void zh_log(const ZHooks *h, const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (h->log) h->log(h->ud, line);
}

typedef struct {
    bool scriptMethods, genericMethods, metadataUsages, addresses, stringLiterals, minify;
} ZFlags;

typedef struct {
    uint64_t methods, genericMethods, strings, metadata, metadataMethods, addresses;
    bool registrationFound, codeRegistrationFound, usagesFound;
} ZStats;

typedef struct {
    FILE *f;
    ZB line;
    bool pretty;
} ZOut;

static bool zo_open(ZOut *o, const char *path, bool pretty) {
    o->f = fopen(path, "wb");
    if (!o->f) return false;
    static char buffer[1 << 20];
    setvbuf(o->f, buffer, _IOFBF, sizeof buffer);
    zb_init(&o->line);
    o->pretty = pretty;
    return true;
}

static void zo_flush(ZOut *o) {
    if (o->line.n) fwrite(o->line.p, 1, o->line.n, o->f);
    zb_reset(&o->line);
}

static void zo_close(ZOut *o) {
    if (!o->f) return;
    zo_flush(o);
    fclose(o->f);
    zb_free(&o->line);
    o->f = NULL;
}

static void zo_str(ZOut *o, const char *s) {
    zb_putc(&o->line, '"');
    zs_json_escape_into(&o->line, (const uint8_t *)s, strlen(s));
    zb_putc(&o->line, '"');
}

static void zo_sep(ZOut *o, bool first) {
    if (!first) zb_putc(&o->line, ',');
    if (o->pretty) zb_puts(&o->line, "\n");
}

static void zo_method_entry(ZOut *o, bool first, uint64_t addr, const char *name, const char *sig, const char *tsig) {
    zo_sep(o, first);
    if (o->pretty) {
        zb_printf(&o->line, "    {\n      \"Address\": %llu,\n      \"Name\": ", (unsigned long long)addr);
        zo_str(o, name);
        zb_puts(&o->line, ",\n      \"Signature\": ");
        zo_str(o, sig);
        zb_puts(&o->line, ",\n      \"TypeSignature\": ");
        zo_str(o, tsig);
        zb_puts(&o->line, "\n    }");
    } else {
        zb_printf(&o->line, "{\"Address\":%llu,\"Name\":", (unsigned long long)addr);
        zo_str(o, name);
        zb_puts(&o->line, ",\"Signature\":");
        zo_str(o, sig);
        zb_puts(&o->line, ",\"TypeSignature\":");
        zo_str(o, tsig);
        zb_putc(&o->line, '}');
    }
    if (o->line.n > (1 << 20)) zo_flush(o);
}

static void zo_metadata_entry(ZOut *o, bool first, uint64_t addr, const char *name, const char *sig) {
    zo_sep(o, first);
    if (o->pretty) {
        zb_printf(&o->line, "    {\n      \"Address\": %llu,\n      \"Name\": ", (unsigned long long)addr);
        zo_str(o, name);
        zb_puts(&o->line, ",\n      \"Signature\": ");
        if (sig) zo_str(o, sig); else zb_puts(&o->line, "null");
        zb_puts(&o->line, "\n    }");
    } else {
        zb_printf(&o->line, "{\"Address\":%llu,\"Name\":", (unsigned long long)addr);
        zo_str(o, name);
        zb_puts(&o->line, ",\"Signature\":");
        if (sig) zo_str(o, sig); else zb_puts(&o->line, "null");
        zb_putc(&o->line, '}');
    }
    if (o->line.n > (1 << 20)) zo_flush(o);
}

static void zo_metadata_method_entry(ZOut *o, bool first, uint64_t addr, const char *name, uint64_t methodAddr) {
    zo_sep(o, first);
    if (o->pretty) {
        zb_printf(&o->line, "    {\n      \"Address\": %llu,\n      \"Name\": ", (unsigned long long)addr);
        zo_str(o, name);
        zb_printf(&o->line, ",\n      \"MethodAddress\": %llu\n    }", (unsigned long long)methodAddr);
    } else {
        zb_printf(&o->line, "{\"Address\":%llu,\"Name\":", (unsigned long long)addr);
        zo_str(o, name);
        zb_printf(&o->line, ",\"MethodAddress\":%llu}", (unsigned long long)methodAddr);
    }
    if (o->line.n > (1 << 20)) zo_flush(o);
}

static void zo_string_entry(ZOut *o, bool first, uint64_t addr, const uint8_t *bytes, size_t n) {
    zo_sep(o, first);
    if (o->pretty) {
        zb_printf(&o->line, "    {\n      \"Address\": %llu,\n      \"Value\": \"", (unsigned long long)addr);
        zs_json_escape_into(&o->line, bytes, n);
        zb_puts(&o->line, "\"\n    }");
    } else {
        zb_printf(&o->line, "{\"Address\":%llu,\"Value\":\"", (unsigned long long)addr);
        zs_json_escape_into(&o->line, bytes, n);
        zb_puts(&o->line, "\"}");
    }
    if (o->line.n > (1 << 20)) zo_flush(o);
}

static void zo_section_open(ZOut *o, bool firstSection, const char *name) {
    if (firstSection) zb_puts(&o->line, o->pretty ? "{\n" : "{");
    else zb_puts(&o->line, o->pretty ? ",\n" : ",");
    if (o->pretty) zb_printf(&o->line, "  \"%s\": [", name);
    else zb_printf(&o->line, "\"%s\":[", name);
}

static void zo_section_close(ZOut *o, bool empty) {
    if (o->pretty) zb_puts(&o->line, empty ? "]" : "\n  ]");
    else zb_putc(&o->line, ']');
}

static void zo_addresses(ZOut *o, const uint64_t *v, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (i) zb_putc(&o->line, ',');
        if (o->pretty) zb_puts(&o->line, "\n    ");
        zb_printf(&o->line, "%llu", (unsigned long long)v[i]);
        if (o->line.n > (1 << 20)) zo_flush(o);
    }
}

#define ZS_PROGRESS(h, stage, f) do { if ((h)->progress) (h)->progress((h)->ud, (stage), (f)); } while (0)
#define ZS_CANCELLED(h) ((h)->cancelled && (h)->cancelled((h)->ud))

static void zs_push_addr(ZU64 *addrs, const ZImg *img, uint64_t ptr) {
    if (!ptr || !zi_is_text_ptr(img, ptr)) return;
    zu_push(addrs, ptr - (uint64_t)img->header);
}

static void zs_method_signature(ZC *c, const void *method, uint32_t defClassIdx, const char *fullName, const ZCtx *ctx, uint64_t thisType, uint64_t rva, bool generic, ZB *sig, ZB *tsig) {
    ZA *a = &c->a;
    uint32_t flags = a->method_get_flags(method, NULL);
    bool isStatic = (flags & 0x10) != 0;
    uint64_t ret = (uint64_t)(uintptr_t)a->method_get_return_type(method);
    uint32_t pc = a->method_get_param_count(method);
    zc_ctype_sig(c, ret, ctx, sig);
    zb_putc(sig, ' ');
    zc_fixname(fullName, sig);
    zb_puts(sig, " (");
    zb_putc(tsig, zc_tchar(c, ret));
    bool first = true;
    if (!isStatic) {
        uint64_t selfType = thisType ? thisType : (uint64_t)(uintptr_t)a->class_get_type(c->cls[defClassIdx]);
        zc_ctype(c, selfType, NULL, 0, sig);
        zb_puts(sig, " __this");
        zb_putc(tsig, zc_tchar(c, selfType));
        first = false;
    }
    for (uint32_t i = 0; i < pc; i++) {
        if (!first) zb_puts(sig, ", ");
        first = false;
        uint64_t pt = (uint64_t)(uintptr_t)a->method_get_param(method, i);
        zc_ctype_sig(c, pt, ctx, sig);
        const char *pn = a->method_get_param_name ? a->method_get_param_name(method, i) : NULL;
        zb_putc(sig, ' ');
        zc_fixname(pn ? pn : "", sig);
        zb_putc(tsig, zc_tchar(c, pt));
    }
    if (!first) zb_puts(sig, ", ");
    if (generic) zb_printf(sig, "const MethodInfo_%llX* method);", (unsigned long long)rva);
    else zb_puts(sig, "const MethodInfo* method);");
    zb_putc(tsig, 'i');
}

static bool zs_enumerate(ZC *c, const ZHooks *h) {
    ZA *a = &c->a;
    size_t asmCount = 0;
    void **asms = a->domain_get_assemblies(a->domain_get(), &asmCount);
    if (!asms) return false;
    uint64_t total = 0;
    for (size_t i = 0; i < asmCount; i++) {
        const void *img = a->assembly_get_image(asms[i]);
        if (img) total += a->image_get_class_count(img);
    }
    c->cls = (void **)calloc(total + 1, sizeof(void *));
    c->clsAsm = (uint32_t *)calloc(total + 1, sizeof(uint32_t));
    c->asmName = (char **)calloc(asmCount + 1, sizeof(char *));
    c->asmCount = (uint32_t)asmCount;
    if (!c->cls || !c->clsAsm || !c->asmName) return false;
    uint32_t n = 0;
    for (size_t i = 0; i < asmCount; i++) {
        const void *img = a->assembly_get_image(asms[i]);
        if (!img) continue;
        size_t cc = a->image_get_class_count(img);
        const char *in = a->image_get_name ? a->image_get_name(img) : NULL;
        c->asmName[i] = strdup(in ? in : "");
        for (size_t k = 0; k < cc; k++) { c->clsAsm[n] = (uint32_t)i; c->cls[n++] = (void *)a->image_get_class(img, k); }
    }
    c->td = n;
    c->nameNs = (char **)calloc(n + 1, sizeof(char *));
    c->nameNoNs = (char **)calloc(n + 1, sizeof(char *));
    c->clsMethodStart = (uint32_t *)calloc(n + 2, sizeof(uint32_t));
    if (!c->nameNs || !c->nameNoNs || !c->clsMethodStart) return false;
    uint32_t cap = 1 << 16;
    c->defMethod = (const void **)malloc(cap * sizeof(void *));
    c->defClass = (uint32_t *)malloc(cap * sizeof(uint32_t));
    c->defRva = (uint64_t *)malloc(cap * sizeof(uint64_t));
    uint32_t dn = 0;
    for (uint32_t i = 0; i < n; i++) {
        c->clsMethodStart[i] = dn;
        void *k = c->cls[i];
        if (k) {
            void *iter = NULL;
            const void *m;
            while ((m = a->class_get_methods(k, &iter))) {
                if (dn == cap) {
                    cap *= 2;
                    c->defMethod = (const void **)realloc((void *)c->defMethod, cap * sizeof(void *));
                    c->defClass = (uint32_t *)realloc(c->defClass, cap * sizeof(uint32_t));
                    c->defRva = (uint64_t *)realloc(c->defRva, cap * sizeof(uint64_t));
                }
                c->defMethod[dn] = m;
                c->defClass[dn] = i;
                void *p = *(void *const *)m;
                c->defRva[dn] = (p && zi_is_text_ptr(c->img, (uint64_t)(uintptr_t)p)) ? (uint64_t)(uintptr_t)p - (uint64_t)c->img->header : 0;
                dn++;
            }
        }
        if ((i & 0x3FF) == 0) ZS_PROGRESS(h, "Enumerating methods", (double)i / (double)n);
        if (ZS_CANCELLED(h)) return false;
    }
    c->clsMethodStart[n] = dn;
    c->defCount = dn;
    return true;
}

static void zs_setup_handles(ZC *c, const ZHooks *h) {
    c->handleMode = false;
    c->h0 = 0;
    c->stride = 0;
    if (c->td < 2 || !c->cls[0] || !c->cls[c->td - 1]) return;
    const void *t0 = c->a.class_get_type(c->cls[0]);
    const void *t1 = c->a.class_get_type(c->cls[c->td - 1]);
    if (!t0 || !t1) return;
    uint64_t d0 = zc_rd64((uint64_t)(uintptr_t)t0), d1 = zc_rd64((uint64_t)(uintptr_t)t1);
    if (d0 < 0x100000) return;
    c->handleMode = true;
    c->h0 = d0;
    if (d1 > d0 && (d1 - d0) % (c->td - 1) == 0) c->stride = (d1 - d0) / (c->td - 1);
    zh_log(h, "typedef handles: base 0x%llx stride %llu", (unsigned long long)d0, (unsigned long long)c->stride);
}

static void zs_validate_meta(ZC *c, const ZMeta *meta, bool metaOk, const ZHooks *h) {
    c->meta = metaOk ? meta : NULL;
    c->tdMap = false;
    c->byrefBit29 = metaOk && meta->version >= 29;
    if (!metaOk || !meta->tables) return;
    uint32_t n = zm_td_count(meta);
    if (n != c->td || (meta->tdSize % ZM_TD_SIZE) != 0) {
        zh_log(h, "metadata typedef table (%u) does not match runtime classes (%u); generic names unavailable", n, c->td);
        return;
    }
    uint32_t badName = 0, badMethods = 0;
    for (uint32_t i = 0; i < c->td; i++) {
        const char *mn = zm_cstr(meta, zm_rd32(meta, zm_td_off(meta, i)));
        const char *cn = c->cls[i] ? c->a.class_get_name(c->cls[i]) : NULL;
        if (!mn || !cn || strcmp(mn, cn) != 0) badName++;
        if (zm_td_method_start(meta, i) != c->clsMethodStart[i] || zm_td_method_count(meta, i) != c->clsMethodStart[i + 1] - c->clsMethodStart[i]) badMethods++;
    }
    c->tdMap = badName == 0;
    zh_log(h, "metadata typedefs %u, name mismatches %u, method range mismatches %u", n, badName, badMethods);
}

typedef struct {
    uint32_t kind, idx;
    uint64_t rva;
} ZUsage;

typedef struct {
    ZUsage *v;
    size_t n, cap;
} ZUsageVec;

static void zuv_push(ZUsageVec *a, uint32_t kind, uint32_t idx, uint64_t rva) {
    if (a->n == a->cap) {
        size_t cap = a->cap ? a->cap * 2 : 8192;
        ZUsage *p = (ZUsage *)realloc(a->v, cap * sizeof(ZUsage));
        if (!p) return;
        a->v = p; a->cap = cap;
    }
    a->v[a->n].kind = kind;
    a->v[a->n].idx = idx;
    a->v[a->n].rva = rva;
    a->n++;
}

static bool zs_section_is_token_data(const ZSect *s) {
    uint32_t type = s->flags & 0xFF;
    if (type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL) return false;
    return strcmp(s->sect, "__const") == 0 || strcmp(s->sect, "__cstring") == 0 || strcmp(s->sect, "__data") == 0;
}

static bool zs_section_bytes(const ZImg *img, const ZSect *s, const uint8_t **bytes, uint8_t **owned) {
    *owned = NULL;
    uint64_t at = (uint64_t)s->offset + img->fileBase;
    if (img->file && s->offset && at + s->size <= img->fileSize) {
        *bytes = img->file + at;
        return true;
    }
    if (s->size == 0 || s->size > ((uint64_t)1 << 31)) return false;
    uint8_t *buf = (uint8_t *)calloc(1, (size_t)s->size);
    if (!buf) return false;
    uint64_t base = (uint64_t)((int64_t)s->addr + img->slide);
    for (uint64_t off = 0; off < s->size; off += 1 << 20) {
        size_t n = (size_t)((s->size - off) < (1 << 20) ? (s->size - off) : (1 << 20));
        zc_rd(base + off, buf + off, n);
    }
    *bytes = buf;
    *owned = buf;
    return true;
}

static bool zs_scan_usages(ZC *c, const ZMeta *meta, const ZR *r, const ZHooks *h, ZUsageVec *out) {
    ZImg *img = c->img;
    uint32_t strCount = zm_string_count(meta);
    uint32_t nTypes = r->haveMR ? r->nTypes : 0;
    uint32_t nSpecs = r->haveMR ? r->nSpecs : 0;
    uint32_t nFieldRefs = zm_field_ref_count(meta);
    int sections = 0, done = 0;
    for (int i = 0; i < img->nsects; i++) if (zs_section_is_token_data(&img->sects[i])) sections++;
    for (int i = 0; i < img->nsects; i++) {
        const ZSect *sc = &img->sects[i];
        if (!zs_section_is_token_data(sc)) continue;
        const uint8_t *bytes;
        uint8_t *owned;
        if (!zs_section_bytes(img, sc, &bytes, &owned)) { done++; continue; }
        uint64_t slots = sc->size / 8;
        for (uint64_t k = 0; k < slots; k++) {
            uint64_t v;
            memcpy(&v, bytes + k * 8, 8);
            if (v >= 0xFFFFFFFFull) continue;
            uint32_t enc = (uint32_t)v;
            uint32_t kind = enc >> 29;
            if (kind < 1 || kind > 6 || !(enc & 1)) continue;
            uint32_t idx = (enc & 0x1FFFFFFEu) >> 1;
            bool ok = false;
            switch (kind) {
                case 1: case 2: ok = idx < nTypes; break;
                case 3: ok = idx < c->defCount; break;
                case 4: ok = idx < nFieldRefs; break;
                case 5: ok = idx < strCount; break;
                case 6: ok = idx < nSpecs; break;
            }
            if (!ok) continue;
            zuv_push(out, kind, idx, sc->addr + k * 8 - img->textVM);
            if ((k & 0xFFFFF) == 0 && ZS_CANCELLED(h)) { free(owned); return false; }
        }
        free(owned);
        done++;
        ZS_PROGRESS(h, "Scanning metadata usages", (double)done / (double)(sections ? sections : 1));
        if (ZS_CANCELLED(h)) return false;
    }
    return true;
}

static void zs_scan_legacy_usages(ZC *c, const ZMeta *meta, const ZR *r, ZUsageVec *out) {
    ZImg *img = c->img;
    if (!r->haveMR || r->nUsages == 0 || !r->usages || !img->file || !zi_in_img(img, r->usages, r->nUsages * 8)) return;
    uint32_t strCount = zm_string_count(meta);
    const uint64_t *arr = (const uint64_t *)(uintptr_t)r->usages;
    for (uint64_t i = 0; i < r->nUsages; i++) {
        uint64_t slot = arr[i], tok;
        if (!zi_file_u64(img, slot, &tok) || (tok >> 32)) continue;
        uint32_t kind = (uint32_t)((tok >> 29) & 7), idx = (uint32_t)(tok & 0x1FFFFFFF);
        if (kind == 5 && idx < strCount) zuv_push(out, 5, idx, slot - (uint64_t)img->header);
    }
}

typedef struct {
    uint64_t inst, type;
    uint32_t td;
    bool used;
} ZGEnt;

typedef struct {
    ZGEnt *e;
    size_t cap;
} ZGMap;

static size_t zg_slot(const ZGMap *m, uint32_t td, uint64_t inst) {
    uint64_t h = (inst * 0x9E3779B97F4A7C15ull) ^ ((uint64_t)td * 0xC2B2AE3D27D4EB4Full);
    return (size_t)(h >> 17) & (m->cap - 1);
}

static void zg_put(ZGMap *m, uint32_t td, uint64_t inst, uint64_t type) {
    size_t i = zg_slot(m, td, inst);
    while (m->e[i].used && !(m->e[i].td == td && m->e[i].inst == inst)) i = (i + 1) & (m->cap - 1);
    m->e[i].used = true; m->e[i].td = td; m->e[i].inst = inst; m->e[i].type = type;
}

static uint64_t zg_get(const ZGMap *m, uint32_t td, uint64_t inst) {
    if (!m->e) return 0;
    size_t i = zg_slot(m, td, inst);
    while (m->e[i].used) {
        if (m->e[i].td == td && m->e[i].inst == inst) return m->e[i].type;
        i = (i + 1) & (m->cap - 1);
    }
    return 0;
}

static void zg_build(ZC *c, const ZR *r, ZGMap *m) {
    size_t cap = 1024;
    while (cap < (size_t)r->nTypes * 2) cap *= 2;
    m->e = (ZGEnt *)calloc(cap, sizeof(ZGEnt));
    m->cap = m->e ? cap : 0;
    if (!m->e) return;
    for (uint32_t i = 0; i < r->nTypes; i++) {
        uint64_t tp = zc_rd64(r->types + 8ull * i);
        ZType t;
        if (!tp || !zc_rd(tp, &t, sizeof t)) continue;
        if ((int)((t.bits >> 16) & 0xFF) != ZT_GENERICINST) continue;
        uint32_t td;
        if (!zc_gc_td(c, t.data, &td)) continue;
        zg_put(m, td, zc_rd64(t.data + 8), tp);
    }
}

static bool zc_type_td(ZC *c, uint64_t tptr, uint32_t *idx) {
    ZType t;
    if (!tptr || !zc_rd(tptr, &t, sizeof t)) return false;
    if ((int)((t.bits >> 16) & 0xFF) == ZT_GENERICINST) return zc_gc_td(c, t.data, idx);
    return zc_td_from_data(c, t.data, idx);
}

static void zs_spec_names(ZC *c, const ZR *r, const uint32_t *specMethodDef, const int32_t *specClassInst, const int32_t *specMethodInst, uint32_t spec, ZB *typeName, ZB *methodName) {
    uint32_t def = specMethodDef[spec];
    zc_typedef_name(c, c->defClass[def], true, typeName);
    if (specClassInst[spec] >= 0 && (uint32_t)specClassInst[spec] < r->nGenericInsts)
        zc_inst_args(c, zc_rd64(r->genericInsts + 8ull * (uint32_t)specClassInst[spec]), 0, typeName);
    const char *mn = c->a.method_get_name(c->defMethod[def]);
    zb_puts(methodName, mn ? mn : "");
    if (specMethodInst[spec] >= 0 && (uint32_t)specMethodInst[spec] < r->nGenericInsts)
        zc_inst_args(c, zc_rd64(r->genericInsts + 8ull * (uint32_t)specMethodInst[spec]), 0, methodName);
}

static bool zs_generate(ZC *c, const ZMeta *meta, bool metaOk, const char *scriptPath, const char *stringPath, const ZFlags *fl, const ZHooks *h, ZStats *st) {
    ZImg *img = c->img;
    memset(st, 0, sizeof *st);
    zs_setup_handles(c, h);
    zs_validate_meta(c, meta, metaOk, h);
    zc_build_struct_names(c);
    ZR r;
    memset(&r, 0, sizeof r);
    if (zr_find_metadata_registration(img, c->td, &r)) {
        st->registrationFound = true;
        zh_log(h, "metadata registration: types %u, specs %u, generic methods %u, usages %llu", r.nTypes, r.nSpecs, r.nGmt, (unsigned long long)r.nUsages);
        if (!zr_detect_gmt_stride(img, &r)) { zh_log(h, "generic method table stride not recognised"); r.haveMR = false; st->registrationFound = false; }
    } else {
        zh_log(h, "metadata registration not found (typedef count %u)", c->td);
    }
    uint32_t *specMethodDef = NULL;
    int32_t *specClassInst = NULL, *specMethodInst = NULL;
    uint64_t *specRva = NULL;
    uint64_t *gmp = NULL;
    bool crByModules = zr_find_code_registration_modules(img, c->asmCount, &r);
    if (crByModules) zh_log(h, "code registration located through module table: %u modules", r.nCgm);
    if (r.haveMR) {
        uint32_t maxMI = 0;
        for (uint32_t i = 0; i < r.nGmt; i++) {
            uint32_t e[2];
            if (!zc_rd(r.gmt + (uint64_t)i * r.gmtStride, e, 8)) break;
            if (e[1] > maxMI && e[1] < 20000000) maxMI = e[1];
        }
        if (crByModules || zr_find_code_registration(img, &r, maxMI)) {
            st->codeRegistrationFound = true;
            gmp = (uint64_t *)malloc((size_t)r.nGmp * 8);
            if (gmp && !zc_rd(r.gmp, gmp, (size_t)r.nGmp * 8)) { free(gmp); gmp = NULL; }
            if (!r.haveCGM) zr_find_modules(img, &r);
            zh_log(h, "code registration: generic pointers %u, invokers %u, reverse wrappers %u, unresolved calls %u, code gen modules %u", r.nGmp, r.nInvoker, r.nRevp, r.nUnresolved, r.haveCGM ? r.nCgm : 0);
        } else {
            zh_log(h, "code registration not found; generic method pointers unavailable");
        }
        specMethodDef = (uint32_t *)malloc((size_t)r.nSpecs * 4 + 4);
        specClassInst = (int32_t *)malloc((size_t)r.nSpecs * 4 + 4);
        specMethodInst = (int32_t *)malloc((size_t)r.nSpecs * 4 + 4);
        specRva = (uint64_t *)calloc((size_t)r.nSpecs + 1, 8);
        uint32_t *raw = (uint32_t *)malloc((size_t)r.nSpecs * 12 + 12);
        if (raw && specMethodDef && specClassInst && specMethodInst && specRva && zc_rd(r.specs, raw, (size_t)r.nSpecs * 12)) {
            for (uint32_t i = 0; i < r.nSpecs; i++) {
                specMethodDef[i] = raw[i * 3];
                specClassInst[i] = (int32_t)raw[i * 3 + 1];
                specMethodInst[i] = (int32_t)raw[i * 3 + 2];
            }
        } else {
            r.haveMR = false;
            zh_log(h, "method specs could not be read");
        }
        free(raw);
    }

    if (!r.haveMR && r.haveCR) {
        st->codeRegistrationFound = true;
        gmp = (uint64_t *)malloc((size_t)r.nGmp * 8 + 8);
        if (gmp && r.nGmp && !zc_rd(r.gmp, gmp, (size_t)r.nGmp * 8)) { free(gmp); gmp = NULL; }
        zh_log(h, "code registration: generic pointers %u, invokers %u, reverse wrappers %u, unresolved calls %u, code gen modules %u", r.nGmp, r.nInvoker, r.nRevp, r.nUnresolved, r.nCgm);
    }
    if (r.haveCGM && c->a.method_get_token) {
        uint32_t resolved = 0;
        for (uint32_t m = 0; m < r.nCgm; m++) {
            uint64_t mod = zc_rd64(r.cgm + 8ull * m);
            uint64_t nameP = zc_rd64(mod), cnt = zc_rd64(mod + 8) & 0xFFFFFFFFull, arr = zc_rd64(mod + 16);
            char mn[128] = {0};
            if (!nameP || !arr || !cnt || !zc_rd(nameP, mn, 127)) continue;
            size_t ml = strlen(mn);
            if (ml > 4 && strcasecmp(mn + ml - 4, ".dll") == 0) mn[ml - 4] = 0;
            uint32_t ai = UINT32_MAX;
            for (uint32_t k = 0; k < c->asmCount; k++) {
                char an[128];
                strncpy(an, c->asmName[k], 127); an[127] = 0;
                size_t al = strlen(an);
                if (al > 4 && strcasecmp(an + al - 4, ".dll") == 0) an[al - 4] = 0;
                if (strcasecmp(an, mn) == 0) { ai = k; break; }
            }
            if (ai == UINT32_MAX) continue;
            uint64_t *ptrs = (uint64_t *)malloc((size_t)cnt * 8);
            if (!ptrs || !zc_rd(arr, ptrs, (size_t)cnt * 8)) { free(ptrs); continue; }
            for (uint32_t d = 0; d < c->defCount; d++) {
                if (c->clsAsm[c->defClass[d]] != ai) continue;
                uint32_t rid = c->a.method_get_token(c->defMethod[d]) & 0xFFFFFF;
                if (!rid || rid > cnt) continue;
                uint64_t pv = ptrs[rid - 1];
                if (pv && zi_is_text_ptr(img, pv) && !c->defRva[d]) { c->defRva[d] = pv - (uint64_t)img->header; resolved++; }
            }
            free(ptrs);
        }
        zh_log(h, "method pointers resolved through code gen modules: %u", resolved);
    }

    int32_t *defHead = NULL, *defTail = NULL, *entNext = NULL;
    uint32_t *entSpec = NULL;
    uint32_t entCount = 0;
    ZU64 addrs = {0};
    if (r.haveMR && gmp && st->codeRegistrationFound) {
        defHead = (int32_t *)malloc((size_t)(c->defCount + 1) * 4);
        defTail = (int32_t *)malloc((size_t)(c->defCount + 1) * 4);
        entNext = (int32_t *)malloc((size_t)r.nGmt * 4 + 4);
        entSpec = (uint32_t *)malloc((size_t)r.nGmt * 4 + 4);
        if (defHead && defTail && entNext && entSpec) {
            for (uint32_t i = 0; i <= c->defCount; i++) { defHead[i] = -1; defTail[i] = -1; }
            for (uint32_t k = 0; k < r.nGmt; k++) {
                uint32_t e[2];
                if (!zc_rd(r.gmt + (uint64_t)k * r.gmtStride, e, 8)) break;
                uint32_t spec = e[0], mi = e[1];
                if (spec >= r.nSpecs || mi >= r.nGmp) continue;
                uint64_t ptr = gmp[mi];
                if (!ptr || !zi_is_text_ptr(img, ptr)) continue;
                specRva[spec] = ptr - (uint64_t)img->header;
                uint32_t def = specMethodDef[spec];
                if (def >= c->defCount) continue;
                entSpec[entCount] = spec;
                entNext[entCount] = -1;
                if (defTail[def] >= 0) entNext[defTail[def]] = (int32_t)entCount; else defHead[def] = (int32_t)entCount;
                defTail[def] = (int32_t)entCount;
                entCount++;
            }
        }
    }

    ZGMap gmap = {0};
    ZOut out = {0};
    bool wantScript = fl->scriptMethods || fl->metadataUsages || fl->addresses || fl->genericMethods;
    bool ok = true;
    if (wantScript) {
        if (!zo_open(&out, scriptPath, !fl->minify)) { zh_log(h, "could not create script.json"); ok = false; }
    }
    ZB nameB, sigB, tsigB, typeB, methB;
    zb_init(&nameB); zb_init(&sigB); zb_init(&tsigB); zb_init(&typeB); zb_init(&methB);
    bool firstSection = true;

    if (ok && wantScript) {
        if (fl->genericMethods && entCount) zg_build(c, &r, &gmap);
        zo_section_open(&out, firstSection, "ScriptMethod");
        firstSection = false;
        bool first = true;
        for (uint32_t d = 0; d < c->defCount && ok; d++) {
            uint64_t rva = c->defRva[d];
            if (rva && fl->scriptMethods) {
                zb_reset(&nameB); zb_reset(&sigB); zb_reset(&tsigB);
                uint32_t ci = c->defClass[d];
                zc_typedef_name_gp(c, ci, true, &nameB);
                const char *mn = c->a.method_get_name(c->defMethod[d]);
                zb_puts(&nameB, "$$");
                zb_puts(&nameB, mn ? mn : "");
                zs_method_signature(c, c->defMethod[d], ci, nameB.p, NULL, 0, rva, false, &sigB, &tsigB);
                zo_method_entry(&out, first, rva, nameB.p, sigB.p, tsigB.p);
                first = false;
                st->methods++;
            }
            if (fl->genericMethods && defHead) {
                for (int32_t e = defHead[d]; e >= 0; e = entNext[e]) {
                    uint32_t spec = entSpec[e];
                    uint64_t grva = specRva[spec];
                    uint32_t ci = c->defClass[d];
                    zb_reset(&nameB); zb_reset(&sigB); zb_reset(&tsigB); zb_reset(&typeB); zb_reset(&methB);
                    zs_spec_names(c, &r, specMethodDef, specClassInst, specMethodInst, spec, &typeB, &methB);
                    zb_puts(&nameB, typeB.p ? typeB.p : "");
                    zb_puts(&nameB, "$$");
                    zb_puts(&nameB, methB.p ? methB.p : "");
                    ZCtx ctx = {0, 0, true};
                    if (specClassInst[spec] >= 0 && (uint32_t)specClassInst[spec] < r.nGenericInsts) ctx.cls = zc_rd64(r.genericInsts + 8ull * (uint32_t)specClassInst[spec]);
                    if (specMethodInst[spec] >= 0 && (uint32_t)specMethodInst[spec] < r.nGenericInsts) ctx.mth = zc_rd64(r.genericInsts + 8ull * (uint32_t)specMethodInst[spec]);
                    uint64_t thisType = specClassInst[spec] >= 0 ? zg_get(&gmap, ci, ctx.cls) : 0;
                    zs_method_signature(c, c->defMethod[d], ci, nameB.p, &ctx, thisType, grva, true, &sigB, &tsigB);
                    zo_method_entry(&out, first, grva, nameB.p, sigB.p, tsigB.p);
                    first = false;
                    st->genericMethods++;
                }
            }
            if ((d & 0x3FFF) == 0) ZS_PROGRESS(h, "Writing methods", (double)d / (double)(c->defCount ? c->defCount : 1));
            if (ZS_CANCELLED(h)) { ok = false; break; }
        }
        zo_section_close(&out, first);
    }

    ZUsageVec usages = {0};
    bool needUsages = ok && metaOk && (fl->stringLiterals || fl->scriptMethods || fl->metadataUsages);
    if (needUsages) {
        if (meta->version >= 27) {
            if (!zs_scan_usages(c, meta, &r, h, &usages)) ok = false;
        } else {
            zs_scan_legacy_usages(c, meta, &r, &usages);
        }
        for (size_t i = 0; i < usages.n; i++) if (usages.v[i].kind == 5) st->strings++;
        st->usagesFound = usages.n > 0;
        zh_log(h, "metadata usage slots: %zu (strings %llu)", usages.n, (unsigned long long)st->strings);
    }

    if (ok && wantScript && fl->scriptMethods && metaOk) {
        zo_section_open(&out, false, "ScriptString");
        bool first = true;
        for (size_t i = 0; i < usages.n; i++) {
            if (usages.v[i].kind != 5) continue;
            const uint8_t *b; uint32_t len;
            if (!zm_string(meta, usages.v[i].idx, &b, &len)) continue;
            zo_string_entry(&out, first, usages.v[i].rva, b, len);
            first = false;
        }
        zo_section_close(&out, first);
    }

    if (ok && wantScript && fl->metadataUsages) {
        ZOut *o = &out;
        zo_section_open(o, false, "ScriptMetadata");
        bool first = true;
        for (size_t i = 0; i < usages.n && ok; i++) {
            const ZUsage *u = &usages.v[i];
            if (u->kind != 1 && u->kind != 2 && u->kind != 4) continue;
            zb_reset(&nameB); zb_reset(&sigB);
            if (u->kind == 4) {
                uint32_t ti, fi, td;
                if (!zm_field_ref(meta, u->idx, &ti, &fi) || !r.haveMR || ti >= r.nTypes || !c->tdMap) continue;
                uint64_t tp = zc_rd64(r.types + 8ull * ti);
                if (!zc_type_td(c, tp, &td)) continue;
                const char *fnm = zm_field_name(meta, (uint64_t)zm_td_field_start(meta, td) + fi);
                zb_puts(&nameB, "Field$");
                zc_type_name(c, tp, true, 0, &nameB);
                zb_putc(&nameB, '.');
                zb_puts(&nameB, fnm ? fnm : "");
                zo_metadata_entry(o, first, u->rva, nameB.p, NULL);
            } else {
                uint64_t tp = zc_rd64(r.types + 8ull * u->idx);
                zc_type_name(c, tp, true, 0, &nameB);
                if (u->kind == 1) {
                    zb_puts(&nameB, "_TypeInfo");
                    zc_struct_name(c, tp, NULL, 0, &sigB);
                    if (sigB.n >= 6 && strcmp(sigB.p + sigB.n - 6, "_array") == 0) {
                        zb_reset(&sigB);
                        zb_puts(&sigB, "Il2CppClass*");
                    } else {
                        zb_reset(&tsigB);
                        zc_fixname(sigB.p ? sigB.p : "", &tsigB);
                        zb_puts(&tsigB, "_c*");
                        zb_reset(&sigB);
                        zb_puts(&sigB, tsigB.p);
                    }
                    zo_metadata_entry(o, first, u->rva, nameB.p, sigB.p);
                } else {
                    zb_puts(&nameB, "_var");
                    zo_metadata_entry(o, first, u->rva, nameB.p, "Il2CppType*");
                }
            }
            first = false;
            st->metadata++;
            if ((i & 0x3FFF) == 0) ZS_PROGRESS(h, "Writing metadata usages", (double)i / (double)(usages.n ? usages.n : 1));
            if (ZS_CANCELLED(h)) { ok = false; break; }
        }
        zo_section_close(o, first);

        zo_section_open(o, false, "ScriptMetadataMethod");
        first = true;
        for (size_t i = 0; i < usages.n && ok; i++) {
            const ZUsage *u = &usages.v[i];
            if (u->kind != 3 && u->kind != 6) continue;
            uint64_t methodAddr = 0;
            zb_reset(&nameB);
            zb_puts(&nameB, "Method$");
            if (u->kind == 3) {
                zc_typedef_name_gp(c, c->defClass[u->idx], true, &nameB);
                const char *mn = c->a.method_get_name(c->defMethod[u->idx]);
                zb_putc(&nameB, '.');
                zb_puts(&nameB, mn ? mn : "");
                methodAddr = c->defRva[u->idx];
            } else {
                if (!r.haveMR || specMethodDef[u->idx] >= c->defCount) continue;
                zb_reset(&typeB); zb_reset(&methB);
                zs_spec_names(c, &r, specMethodDef, specClassInst, specMethodInst, u->idx, &typeB, &methB);
                zb_puts(&nameB, typeB.p ? typeB.p : "");
                zb_putc(&nameB, '.');
                zb_puts(&nameB, methB.p ? methB.p : "");
                methodAddr = specRva[u->idx];
            }
            zb_puts(&nameB, "()");
            zo_metadata_method_entry(o, first, u->rva, nameB.p, methodAddr);
            first = false;
            st->metadataMethods++;
            if (ZS_CANCELLED(h)) { ok = false; break; }
        }
        zo_section_close(o, first);
    }

    if (ok && wantScript && fl->addresses) {
        if (r.haveCGM) {
            for (uint32_t m = 0; m < r.nCgm; m++) {
                uint64_t mod = zc_rd64(r.cgm + 8ull * m);
                uint64_t cnt = zc_rd64(mod + 8), arr = zc_rd64(mod + 16);
                if (!mod || !arr || cnt == 0 || cnt > 4000000 || !zi_in_img(img, arr, cnt * 8)) continue;
                uint64_t *buf = (uint64_t *)malloc((size_t)cnt * 8);
                if (buf && zc_rd(arr, buf, (size_t)cnt * 8)) for (uint64_t i = 0; i < cnt; i++) zs_push_addr(&addrs, img, buf[i]);
                free(buf);
            }
        } else {
            for (uint32_t d = 0; d < c->defCount; d++) if (c->defRva[d]) zs_push_addr(&addrs, img, c->defRva[d] + (uint64_t)img->header);
        }
        if (r.haveCR) {
            if (gmp) for (uint32_t i = 0; i < r.nGmp; i++) zs_push_addr(&addrs, img, gmp[i]);
            for (uint32_t i = 0; i < r.nInvoker && r.invoker; i++) zs_push_addr(&addrs, img, zc_rd64(r.invoker + 8ull * i));
            for (uint32_t i = 0; i < r.nRevp && r.revp; i++) zs_push_addr(&addrs, img, zc_rd64(r.revp + 8ull * i));
            for (uint32_t i = 0; i < r.nUnresolved && r.unresolved; i++) zs_push_addr(&addrs, img, zc_rd64(r.unresolved + 8ull * i));
        }
        qsort(addrs.v, addrs.n, 8, zu_cmp);
        size_t u = 0;
        for (size_t i = 0; i < addrs.n; i++) if (i == 0 || addrs.v[i] != addrs.v[i - 1]) addrs.v[u++] = addrs.v[i];
        zo_section_open(&out, false, "Addresses");
        zo_addresses(&out, addrs.v, u);
        zo_section_close(&out, u == 0);
        st->addresses = u;
    }

    if (wantScript && out.f) {
        zb_puts(&out.line, out.pretty ? "\n}" : "}");
        zo_close(&out);
    }

    if (ok && fl->stringLiterals && metaOk) {
        ZOut so = {0};
        if (zo_open(&so, stringPath, !fl->minify)) {
            zb_putc(&so.line, '[');
            bool first = true;
            for (size_t i = 0; i < usages.n; i++) {
                if (usages.v[i].kind != 5) continue;
                const uint8_t *b; uint32_t len;
                if (!zm_string(meta, usages.v[i].idx, &b, &len)) continue;
                zo_sep(&so, first);
                first = false;
                zb_puts(&so.line, so.pretty ? "  {\n    \"value\": \"" : "{\"value\":\"");
                zs_json_escape_into(&so.line, b, len);
                zb_printf(&so.line, so.pretty ? "\",\n    \"address\": \"0x%llX\"\n  }" : "\",\"address\":\"0x%llX\"}", (unsigned long long)usages.v[i].rva);
                if (so.line.n > (1 << 20)) zo_flush(&so);
            }
            zb_puts(&so.line, (so.pretty && !first) ? "\n]" : "]");
            zo_close(&so);
        } else {
            zh_log(h, "could not create stringliteral.json");
        }
    }

    zb_free(&nameB); zb_free(&sigB); zb_free(&tsigB); zb_free(&typeB); zb_free(&methB);
    free(addrs.v); free(usages.v); free(gmap.e);
    free(defHead); free(defTail); free(entNext); free(entSpec);
    free(specMethodDef); free(specClassInst); free(specMethodInst); free(specRva); free(gmp);
    return ok;
}

static void zc_release(ZC *c) {
    for (uint32_t i = 0; i < c->td; i++) {
        if (c->nameNs) free(c->nameNs[i]);
        if (c->nameNoNs) free(c->nameNoNs[i]);
        if (c->structBase) free(c->structBase[i]);
        if (c->structName) free(c->structName[i]);
    }
    if (c->asmName) for (uint32_t i = 0; i < c->asmCount; i++) free(c->asmName[i]);
    free(c->asmName); free(c->clsAsm);
    free(c->nameNs); free(c->nameNoNs); free(c->structBase); free(c->structName); free(c->cls); free(c->clsMethodStart);
    free((void *)c->defMethod); free(c->defClass); free(c->defRva);
}
