#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
    a->memory_free = (void (*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_free");
    return a->domain_get && a->domain_get_assemblies && a->assembly_get_image && a->image_get_class_count && a->image_get_class &&
           a->class_get_name && a->class_get_namespace && a->class_get_methods && a->class_get_type && a->method_get_name &&
           a->method_get_return_type && a->method_get_param_count && a->method_get_param && a->method_get_flags;
}

typedef struct { char name[17]; uint64_t vmaddr, vmsize, fileoff, filesize; } ZSeg;
typedef struct { char seg[17]; char sect[17]; uint64_t addr, size; uint32_t flags; } ZSect;

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
                    s->addr = sec[k].addr; s->size = sec[k].size; s->flags = sec[k].flags;
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

typedef struct {
    ZA a;
    ZImg *img;
    void **cls;
    uint32_t td;
    bool handleMode;
    uint64_t h0, stride;
    char **nameNs;
    char **nameNoNs;
    uint32_t *clsMethodStart;
    uint32_t defCount;
    const void **defMethod;
    uint32_t *defClass;
    uint64_t *defRva;
} ZC;

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

static const char *zc_prim_clr(int t) {
    switch (t) {
        case ZT_BOOLEAN: return "System.Boolean";
        case ZT_CHAR: return "System.Char";
        case ZT_I1: return "System.SByte";
        case ZT_U1: return "System.Byte";
        case ZT_I2: return "System.Int16";
        case ZT_U2: return "System.UInt16";
        case ZT_I4: return "System.Int32";
        case ZT_U4: return "System.UInt32";
        case ZT_I8: return "System.Int64";
        case ZT_U8: return "System.UInt64";
        case ZT_R4: return "System.Single";
        case ZT_R8: return "System.Double";
        case ZT_STRING: return "System.String";
        case ZT_OBJECT: return "System.Object";
        case ZT_I: return "System.IntPtr";
        case ZT_U: return "System.UIntPtr";
        default: return NULL;
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
            if (zc_td_from_data(c, t.data, &idx)) zc_typedef_name(c, idx, ns, out);
            else zb_puts(out, "?");
            return;
        case ZT_GENERICINST: {
            uint64_t gc = t.data;
            if (zc_td_from_data(c, zc_rd64(gc), &idx)) zc_typedef_name(c, idx, ns, out);
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
    for (size_t i = from; i < b->n; i++) {
        char ch = b->p[i];
        bool ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_';
        if (!ok) b->p[i] = '_';
    }
}

static void zc_ctype(ZC *c, uint64_t tptr, int depth, ZB *out);

static void zc_elem_clr_name(ZC *c, uint64_t tptr, int depth, ZB *out) {
    ZType t;
    if (!zc_rd(tptr, &t, sizeof t)) { zb_puts(out, "Il2CppObject"); return; }
    int ty = (int)((t.bits >> 16) & 0xFF);
    const char *clr = zc_prim_clr(ty);
    if (clr) { zb_puts(out, clr); return; }
    zc_type_name(c, tptr, true, depth + 1, out);
}

static bool zc_enum_underlying(ZC *c, uint32_t idx, uint64_t *base) {
    if (idx >= c->td || !c->a.class_is_enum || !c->a.class_enum_basetype) return false;
    if (!c->a.class_is_enum(c->cls[idx])) return false;
    const void *bt = c->a.class_enum_basetype(c->cls[idx]);
    if (!bt) return false;
    *base = (uint64_t)(uintptr_t)bt;
    return true;
}

static void zc_ctype(ZC *c, uint64_t tptr, int depth, ZB *out) {
    ZType t;
    if (depth > 8 || !tptr || !zc_rd(tptr, &t, sizeof t)) { zb_puts(out, "Il2CppObject*"); return; }
    int ty = (int)((t.bits >> 16) & 0xFF);
    bool byref = ((t.bits >> 30) & 1) != 0;
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
        case ZT_OBJECT: zb_puts(out, "Il2CppObject*"); break;
        case ZT_STRING: zb_puts(out, "System_String_o*"); break;
        case ZT_PTR:
            zc_ctype(c, t.data, depth + 1, out);
            zb_putc(out, '*');
            break;
        case ZT_FNPTR: zb_puts(out, "void*"); break;
        case ZT_SZARRAY:
        case ZT_ARRAY: {
            size_t from = out->n;
            uint64_t elem = ty == ZT_ARRAY ? zc_rd64(t.data) : t.data;
            zc_elem_clr_name(c, elem, depth, out);
            zc_fix(out, from);
            zb_puts(out, "_array*");
            break;
        }
        case ZT_CLASS:
        case ZT_VALUETYPE:
        case ZT_GENERICINST: {
            uint32_t idx;
            bool valueType = ty == ZT_VALUETYPE;
            uint64_t handle = ty == ZT_GENERICINST ? zc_rd64(t.data) : t.data;
            if (!zc_td_from_data(c, handle, &idx)) { zb_puts(out, "Il2CppObject*"); break; }
            if (ty == ZT_GENERICINST) valueType = c->a.class_is_valuetype && c->a.class_is_valuetype(c->cls[idx]);
            uint64_t under;
            if (ty != ZT_GENERICINST && valueType && zc_enum_underlying(c, idx, &under)) {
                zc_ctype(c, under, depth + 1, out);
                break;
            }
            size_t from = out->n;
            zc_type_name(c, tptr, true, depth + 1, out);
            zc_fix(out, from);
            zb_puts(out, valueType ? "_o" : "_o*");
            break;
        }
        default:
            zb_puts(out, "Il2CppObject*");
            break;
    }
    if (byref) zb_putc(out, '*');
}

static char zc_tchar(ZC *c, uint64_t tptr, int depth) {
    ZType t;
    if (depth > 4 || !tptr || !zc_rd(tptr, &t, sizeof t)) return 'i';
    if ((t.bits >> 30) & 1) return 'i';
    int ty = (int)((t.bits >> 16) & 0xFF);
    switch (ty) {
        case ZT_VOID: return 'v';
        case ZT_I8: case ZT_U8: return 'j';
        case ZT_R4: return 'f';
        case ZT_R8: return 'd';
        case ZT_VALUETYPE: {
            uint32_t idx;
            uint64_t under;
            if (zc_td_from_data(c, t.data, &idx) && zc_enum_underlying(c, idx, &under)) return zc_tchar(c, under, depth + 1);
            return 'i';
        }
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
    bool haveMR, haveCR;
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
            if (!zi_is_data_ptr(img, q[1])) continue;
            if (q[2] > 0x4000000) continue;
            if (q[2] && !zi_is_data_ptr(img, q[3])) continue;
            const uint64_t *s = q - 12;
            bool ok = true;
            for (int i = 0; i < 12 && ok; i += 2) {
                if (s[i] == 0 || s[i] > 0x4000000 || !zi_is_data_ptr(img, s[i + 1])) ok = false;
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
            return true;
        }
    }
    return false;
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
    uint64_t *slots;
    size_t cap;
    size_t count;
} ZSet;

static bool zset_init(ZSet *s, size_t want) {
    size_t cap = 1024;
    while (cap < want * 2) cap *= 2;
    s->slots = (uint64_t *)calloc(cap, 8);
    s->cap = cap;
    s->count = 0;
    return s->slots != NULL;
}

static bool zset_add(ZSet *s, uint64_t key) {
    key += 1;
    size_t h = (size_t)((key * 0x9E3779B97F4A7C15ull) >> 20) & (s->cap - 1);
    while (s->slots[h]) {
        if (s->slots[h] == key) return false;
        h = (h + 1) & (s->cap - 1);
    }
    s->slots[h] = key;
    s->count++;
    return true;
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

typedef struct {
    const uint8_t *p;
    size_t size;
    uint32_t version;
    uint32_t strLitOff, strLitSize, strDataOff, strDataSize;
} ZMeta;

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
    uint32_t h[8];
    memcpy(h, m->p, sizeof h);
    if (h[0] != 0xFAB11BAF) return false;
    m->version = h[1];
    m->strLitOff = h[2]; m->strLitSize = h[3]; m->strDataOff = h[4]; m->strDataSize = h[5];
    if ((uint64_t)m->strLitOff + m->strLitSize > m->size || (uint64_t)m->strDataOff + m->strDataSize > m->size) return false;
    return true;
}

static uint32_t zm_string_count(const ZMeta *m) { return m->strLitSize / 8; }

static bool zm_string(const ZMeta *m, uint32_t idx, const uint8_t **bytes, uint32_t *len) {
    if (idx >= zm_string_count(m)) return false;
    uint32_t e[2];
    memcpy(e, m->p + m->strLitOff + (size_t)idx * 8, 8);
    if ((uint64_t)e[1] + e[0] > m->strDataSize) return false;
    *bytes = m->p + m->strDataOff + e[1];
    *len = e[0];
    return true;
}

static bool zm_find_string_slots(const ZImg *img, uint32_t count, uint64_t *baseRt) {
    if (!img->file || count == 0) return false;
    const uint64_t tag = 5ull << 29;
    for (int i = 0; i < img->nsegs; i++) {
        const ZSeg *s = &img->segs[i];
        if (strncmp(s->name, "__DATA", 6) != 0 || s->filesize < (uint64_t)count * 8) continue;
        if (s->fileoff + s->filesize + img->fileBase > img->fileSize) continue;
        const uint64_t *q = (const uint64_t *)(img->file + img->fileBase + s->fileoff);
        uint64_t n = s->filesize / 8;
        for (uint64_t j = 0; j + count <= n; j++) {
            if (q[j] != tag) continue;
            if (q[j + count - 1] != tag + count - 1) continue;
            uint64_t step = count > 64 ? count / 64 : 1;
            bool ok = true;
            for (uint64_t k = 0; k < count && ok; k += step) ok = q[j + k] == tag + k;
            if (!ok) continue;
            *baseRt = (uint64_t)((int64_t)s->vmaddr + img->slide) + j * 8;
            return true;
        }
    }
    return false;
}

#define ZS_PROGRESS(h, stage, f) do { if ((h)->progress) (h)->progress((h)->ud, (stage), (f)); } while (0)
#define ZS_CANCELLED(h) ((h)->cancelled && (h)->cancelled((h)->ud))

static void zs_push_addr(ZU64 *addrs, const ZImg *img, uint64_t ptr) {
    if (!ptr || !zi_is_text_ptr(img, ptr)) return;
    zu_push(addrs, ptr - (uint64_t)img->header);
}

static void zs_method_signature(ZC *c, const void *method, uint32_t defClassIdx, const char *typeFixedName, const char *methodNameFull, bool generic, uint64_t rva, ZB *sig, ZB *tsig) {
    ZA *a = &c->a;
    uint32_t flags = a->method_get_flags(method, NULL);
    bool isStatic = (flags & 0x10) != 0;
    uint64_t ret = (uint64_t)(uintptr_t)a->method_get_return_type(method);
    uint32_t pc = a->method_get_param_count(method);
    zc_ctype(c, ret, 0, sig);
    zb_putc(sig, ' ');
    size_t from = sig->n;
    zb_puts(sig, typeFixedName);
    zb_puts(sig, "__");
    zb_puts(sig, methodNameFull);
    zc_fix(sig, from);
    zb_puts(sig, " (");
    zb_putc(tsig, zc_tchar(c, ret, 0));
    bool first = true;
    if (!isStatic) {
        uint64_t selfType = (uint64_t)(uintptr_t)a->class_get_type(c->cls[defClassIdx]);
        zc_ctype(c, selfType, 0, sig);
        zb_puts(sig, " __this");
        zb_putc(tsig, 'i');
        first = false;
    }
    for (uint32_t i = 0; i < pc; i++) {
        if (!first) zb_puts(sig, ", ");
        first = false;
        uint64_t pt = (uint64_t)(uintptr_t)a->method_get_param(method, i);
        zc_ctype(c, pt, 0, sig);
        const char *pn = a->method_get_param_name ? a->method_get_param_name(method, i) : NULL;
        zb_putc(sig, ' ');
        zb_puts(sig, pn ? pn : "");
        zb_putc(tsig, zc_tchar(c, pt, 0));
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
    if (!c->cls) return false;
    uint32_t n = 0;
    for (size_t i = 0; i < asmCount; i++) {
        const void *img = a->assembly_get_image(asms[i]);
        if (!img) continue;
        size_t cc = a->image_get_class_count(img);
        for (size_t k = 0; k < cc; k++) c->cls[n++] = (void *)a->image_get_class(img, k);
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

static bool zs_generate(ZC *c, const ZMeta *meta, bool metaOk, const char *scriptPath, const char *stringPath, const ZFlags *fl, const ZHooks *h, ZStats *st) {
    ZImg *img = c->img;
    memset(st, 0, sizeof *st);
    zs_setup_handles(c, h);
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
    if (r.haveMR) {
        uint32_t maxMI = 0;
        uint32_t sampleN = r.nGmt;
        for (uint32_t i = 0; i < sampleN; i++) {
            uint32_t e[2];
            if (!zc_rd(r.gmt + (uint64_t)i * r.gmtStride, e, 8)) break;
            if (e[1] > maxMI && e[1] < 20000000) maxMI = e[1];
        }
        if (zr_find_code_registration(img, &r, maxMI)) {
            st->codeRegistrationFound = true;
            gmp = (uint64_t *)malloc((size_t)r.nGmp * 8);
            if (gmp && !zc_rd(r.gmp, gmp, (size_t)r.nGmp * 8)) { free(gmp); gmp = NULL; }
            zh_log(h, "code registration: generic pointers %u, invokers %u, reverse wrappers %u", r.nGmp, r.nInvoker, r.nRevp);
        } else {
            zh_log(h, "code registration not found; generic method pointers unavailable");
        }
        specMethodDef = (uint32_t *)malloc((size_t)r.nSpecs * 4);
        specClassInst = (int32_t *)malloc((size_t)r.nSpecs * 4);
        specMethodInst = (int32_t *)malloc((size_t)r.nSpecs * 4);
        specRva = (uint64_t *)calloc(r.nSpecs, 8);
        uint32_t *raw = (uint32_t *)malloc((size_t)r.nSpecs * 12);
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

    ZU64 addrs = {0};
    ZSet seen;
    zset_init(&seen, 1 << 20);
    ZOut out = {0};
    bool wantScript = fl->scriptMethods || fl->metadataUsages || fl->addresses || fl->genericMethods;
    bool ok = true;
    if (wantScript) {
        if (!zo_open(&out, scriptPath, !fl->minify)) { zh_log(h, "could not create script.json"); ok = false; }
    }
    ZB nameB, sigB, tsigB, tmp, fixedB;
    zb_init(&nameB); zb_init(&sigB); zb_init(&tsigB); zb_init(&tmp); zb_init(&fixedB);
    bool firstSection = true;

    if (ok && wantScript) {
        zo_section_open(&out, firstSection, "ScriptMethod");
        firstSection = false;
        bool first = true;
        if (fl->scriptMethods) {
            for (uint32_t d = 0; d < c->defCount && ok; d++) {
                uint64_t rva = c->defRva[d];
                if (!rva) continue;
                zs_push_addr(&addrs, img, rva + (uint64_t)img->header);
                if (!zset_add(&seen, rva)) continue;
                zb_reset(&nameB); zb_reset(&sigB); zb_reset(&tsigB); zb_reset(&fixedB);
                uint32_t ci = c->defClass[d];
                zc_typedef_name(c, ci, true, &nameB);
                size_t tl = nameB.n;
                zb_puts(&fixedB, nameB.p);
                const char *mn = c->a.method_get_name(c->defMethod[d]);
                zb_puts(&nameB, "$$");
                zb_puts(&nameB, mn ? mn : "");
                zc_fix(&fixedB, 0);
                (void)tl;
                zs_method_signature(c, c->defMethod[d], ci, fixedB.p, mn ? mn : "", false, rva, &sigB, &tsigB);
                zo_method_entry(&out, first, rva, nameB.p, sigB.p, tsigB.p);
                first = false;
                st->methods++;
                if ((d & 0x3FFF) == 0) ZS_PROGRESS(h, "Writing methods", (double)d / (double)(c->defCount ? c->defCount : 1));
                if (ZS_CANCELLED(h)) { ok = false; break; }
            }
        } else {
            for (uint32_t d = 0; d < c->defCount; d++) if (c->defRva[d]) zs_push_addr(&addrs, img, c->defRva[d] + (uint64_t)img->header);
        }
        if (ok && r.haveMR && gmp) {
            for (uint32_t k = 0; k < r.nGmt && ok; k++) {
                uint32_t e[2];
                if (!zc_rd(r.gmt + (uint64_t)k * r.gmtStride, e, 8)) break;
                uint32_t spec = e[0], mi = e[1];
                if (spec >= r.nSpecs || mi >= r.nGmp) continue;
                uint64_t ptr = gmp[mi];
                if (!ptr || !zi_is_text_ptr(img, ptr)) continue;
                uint64_t rva = ptr - (uint64_t)img->header;
                specRva[spec] = rva;
                zs_push_addr(&addrs, img, ptr);
                if (!fl->genericMethods) continue;
                if (!zset_add(&seen, rva)) continue;
                uint32_t def = specMethodDef[spec];
                if (def >= c->defCount) continue;
                uint32_t ci = c->defClass[def];
                zb_reset(&nameB); zb_reset(&sigB); zb_reset(&tsigB); zb_reset(&fixedB);
                zc_typedef_name(c, ci, true, &nameB);
                if (specClassInst[spec] >= 0 && (uint32_t)specClassInst[spec] < r.nGenericInsts)
                    zc_inst_args(c, zc_rd64(r.genericInsts + 8ull * (uint32_t)specClassInst[spec]), 0, &nameB);
                zb_puts(&fixedB, nameB.p);
                zc_fix(&fixedB, 0);
                zb_puts(&nameB, "$$");
                size_t mstart = nameB.n;
                const char *mn = c->a.method_get_name(c->defMethod[def]);
                zb_puts(&nameB, mn ? mn : "");
                if (specMethodInst[spec] >= 0 && (uint32_t)specMethodInst[spec] < r.nGenericInsts)
                    zc_inst_args(c, zc_rd64(r.genericInsts + 8ull * (uint32_t)specMethodInst[spec]), 0, &nameB);
                zs_method_signature(c, c->defMethod[def], ci, fixedB.p, nameB.p + mstart, true, rva, &sigB, &tsigB);
                zo_method_entry(&out, first, rva, nameB.p, sigB.p, tsigB.p);
                first = false;
                st->genericMethods++;
                if ((k & 0x3FFF) == 0) ZS_PROGRESS(h, "Writing generic methods", (double)k / (double)r.nGmt);
                if (ZS_CANCELLED(h)) { ok = false; break; }
            }
        }
        zo_section_close(&out, first);
    }

    ZU64 strIdx = {0}, strRva = {0};
    uint64_t strBase = 0;
    bool haveStrBase = false;
    uint32_t strCount = metaOk ? zm_string_count(meta) : 0;
    if (ok && metaOk && (fl->stringLiterals || fl->scriptMethods)) {
        if (r.haveMR && r.nUsages > 0 && r.usages && img->file) {
            uint64_t n = r.nUsages;
            if (zi_in_img(img, r.usages, n * 8)) {
                const uint64_t *arr = (const uint64_t *)(uintptr_t)r.usages;
                for (uint64_t i = 0; i < n; i++) {
                    uint64_t slot = arr[i], tok;
                    if (!zi_file_u64(img, slot, &tok)) continue;
                    if (((tok >> 29) & 7) != 5 || (tok >> 32)) continue;
                    zu_push(&strIdx, tok & 0x1FFFFFFF);
                    zu_push(&strRva, slot - (uint64_t)img->header);
                }
                st->usagesFound = strIdx.n > 0;
            }
        }
        if (!st->usagesFound && zm_find_string_slots(img, strCount, &strBase)) {
            haveStrBase = true;
            zh_log(h, "string literal slots located by token scan");
        }
    }

    ZU64 order = {0};
    if (ok && wantScript && fl->scriptMethods && metaOk) {
        zo_section_open(&out, false, "ScriptString");
        bool first = true;
        if (st->usagesFound) {
            for (size_t i = 0; i < strIdx.n; i++) zu_push(&order, (strIdx.v[i] << 32) | i);
            qsort(order.v, order.n, 8, zu_cmp);
            uint64_t prev = ~0ull;
            for (size_t i = 0; i < order.n; i++) {
                uint32_t idx = (uint32_t)(order.v[i] >> 32);
                if (idx == prev) continue;
                prev = idx;
                size_t at = (size_t)(order.v[i] & 0xFFFFFFFFu);
                const uint8_t *b; uint32_t len;
                if (!zm_string(meta, idx, &b, &len)) continue;
                zo_string_entry(&out, first, strRva.v[at], b, len);
                first = false;
                st->strings++;
            }
        } else if (haveStrBase) {
            for (uint32_t idx = 0; idx < strCount; idx++) {
                const uint8_t *b; uint32_t len;
                if (!zm_string(meta, idx, &b, &len)) continue;
                zo_string_entry(&out, first, strBase - (uint64_t)img->header + 8ull * idx, b, len);
                first = false;
                st->strings++;
            }
        }
        zo_section_close(&out, first);
    }

    if (ok && wantScript && fl->metadataUsages) {
        bool haveUsage = r.haveMR && r.nUsages > 0 && r.usages && img->file && zi_in_img(img, r.usages, r.nUsages * 8);
        ZOut *o = &out;
        const uint64_t *arr = haveUsage ? (const uint64_t *)(uintptr_t)r.usages : NULL;
        zo_section_open(o, false, "ScriptMetadata");
        bool first = true;
        if (arr) {
            for (uint64_t i = 0; i < r.nUsages && ok; i++) {
                uint64_t tok;
                if (!zi_file_u64(img, arr[i], &tok) || (tok >> 32)) continue;
                uint32_t kind = (uint32_t)((tok >> 29) & 7), idx = (uint32_t)(tok & 0x1FFFFFFF);
                if ((kind != 1 && kind != 2) || idx >= r.nTypes) continue;
                uint64_t tp = zc_rd64(r.types + 8ull * idx);
                zb_reset(&nameB); zb_reset(&fixedB);
                zc_type_name(c, tp, true, 0, &nameB);
                uint64_t rva = arr[i] - (uint64_t)img->header;
                if (kind == 1) {
                    zb_puts(&fixedB, nameB.p);
                    zc_fix(&fixedB, 0);
                    zb_puts(&fixedB, "_c*");
                    zb_puts(&nameB, "_TypeInfo");
                    zo_metadata_entry(o, first, rva, nameB.p, fixedB.p);
                } else {
                    zb_puts(&nameB, "_var");
                    zo_metadata_entry(o, first, rva, nameB.p, "Il2CppType*");
                }
                first = false;
                st->metadata++;
                if ((i & 0x3FFF) == 0) ZS_PROGRESS(h, "Writing metadata usages", (double)i / (double)r.nUsages);
                if (ZS_CANCELLED(h)) { ok = false; break; }
            }
        }
        zo_section_close(o, first);

        zo_section_open(o, false, "ScriptMetadataMethod");
        first = true;
        if (arr) {
            for (uint64_t i = 0; i < r.nUsages && ok; i++) {
                uint64_t tok;
                if (!zi_file_u64(img, arr[i], &tok) || (tok >> 32)) continue;
                uint32_t kind = (uint32_t)((tok >> 29) & 7), idx = (uint32_t)(tok & 0x1FFFFFFF);
                uint64_t methodAddr = 0;
                zb_reset(&nameB);
                zb_puts(&nameB, "Method$");
                if (kind == 3) {
                    if (idx >= c->defCount) continue;
                    zc_typedef_name(c, c->defClass[idx], true, &nameB);
                    const char *mn = c->a.method_get_name(c->defMethod[idx]);
                    zb_putc(&nameB, '.');
                    zb_puts(&nameB, mn ? mn : "");
                    methodAddr = c->defRva[idx];
                } else if (kind == 6) {
                    if (!r.haveMR || idx >= r.nSpecs || specMethodDef[idx] >= c->defCount) continue;
                    uint32_t def = specMethodDef[idx];
                    zc_typedef_name(c, c->defClass[def], true, &nameB);
                    if (specClassInst[idx] >= 0 && (uint32_t)specClassInst[idx] < r.nGenericInsts)
                        zc_inst_args(c, zc_rd64(r.genericInsts + 8ull * (uint32_t)specClassInst[idx]), 0, &nameB);
                    const char *mn = c->a.method_get_name(c->defMethod[def]);
                    zb_putc(&nameB, '.');
                    zb_puts(&nameB, mn ? mn : "");
                    if (specMethodInst[idx] >= 0 && (uint32_t)specMethodInst[idx] < r.nGenericInsts)
                        zc_inst_args(c, zc_rd64(r.genericInsts + 8ull * (uint32_t)specMethodInst[idx]), 0, &nameB);
                    methodAddr = specRva ? specRva[idx] : 0;
                } else {
                    continue;
                }
                zb_puts(&nameB, "()");
                zo_metadata_method_entry(o, first, arr[i] - (uint64_t)img->header, nameB.p, methodAddr);
                first = false;
                st->metadataMethods++;
                if (ZS_CANCELLED(h)) { ok = false; break; }
            }
        }
        zo_section_close(o, first);
    }

    if (ok && wantScript && fl->addresses) {
        if (r.haveCR) {
            if (gmp) for (uint32_t i = 0; i < r.nGmp; i++) zs_push_addr(&addrs, img, gmp[i]);
            for (uint32_t i = 0; i < r.nInvoker && r.invoker; i++) zs_push_addr(&addrs, img, zc_rd64(r.invoker + 8ull * i));
            for (uint32_t i = 0; i < r.nRevp && r.revp; i++) zs_push_addr(&addrs, img, zc_rd64(r.revp + 8ull * i));
            if (r.adj) for (uint32_t i = 0; i < r.nGmp; i++) zs_push_addr(&addrs, img, zc_rd64(r.adj + 8ull * i));
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
            zb_puts(&so.line, so.pretty ? "[" : "[");
            bool first = true;
            if (st->usagesFound) {
                uint64_t prev = ~0ull;
                for (size_t i = 0; i < order.n; i++) {
                    uint32_t idx = (uint32_t)(order.v[i] >> 32);
                    if (idx == prev) continue;
                    prev = idx;
                    size_t at = (size_t)(order.v[i] & 0xFFFFFFFFu);
                    const uint8_t *b; uint32_t len;
                    if (!zm_string(meta, idx, &b, &len)) continue;
                    zo_sep(&so, first);
                    first = false;
                    zb_puts(&so.line, so.pretty ? "  {\n    \"value\": \"" : "{\"value\":\"");
                    zs_json_escape_into(&so.line, b, len);
                    zb_printf(&so.line, so.pretty ? "\",\n    \"address\": \"0x%llX\"\n  }" : "\",\"address\":\"0x%llX\"}", (unsigned long long)strRva.v[at]);
                    if (so.line.n > (1 << 20)) zo_flush(&so);
                }
            } else if (haveStrBase) {
                for (uint32_t idx = 0; idx < strCount; idx++) {
                    const uint8_t *b; uint32_t len;
                    if (!zm_string(meta, idx, &b, &len)) continue;
                    zo_sep(&so, first);
                    first = false;
                    zb_puts(&so.line, so.pretty ? "  {\n    \"value\": \"" : "{\"value\":\"");
                    zs_json_escape_into(&so.line, b, len);
                    zb_printf(&so.line, so.pretty ? "\",\n    \"address\": \"0x%llX\"\n  }" : "\",\"address\":\"0x%llX\"}", (unsigned long long)(strBase - (uint64_t)img->header + 8ull * idx));
                    if (so.line.n > (1 << 20)) zo_flush(&so);
                }
            }
            zb_puts(&so.line, so.pretty ? "\n]" : "]");
            zo_close(&so);
        } else {
            zh_log(h, "could not create stringliteral.json");
        }
    }

    zb_free(&nameB); zb_free(&sigB); zb_free(&tsigB); zb_free(&tmp); zb_free(&fixedB);
    free(addrs.v); free(strIdx.v); free(strRva.v); free(order.v); free(seen.slots);
    free(specMethodDef); free(specClassInst); free(specMethodInst); free(specRva); free(gmp);
    return ok;
}

static void zc_release(ZC *c) {
    if (c->nameNs) for (uint32_t i = 0; i < c->td; i++) free(c->nameNs[i]);
    if (c->nameNoNs) for (uint32_t i = 0; i < c->td; i++) free(c->nameNoNs[i]);
    free(c->nameNs); free(c->nameNoNs); free(c->cls); free(c->clsMethodStart);
    free((void *)c->defMethod); free(c->defClass); free(c->defRva);
}
