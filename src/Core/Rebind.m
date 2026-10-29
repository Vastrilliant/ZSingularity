#import "Rebind.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#import <stdatomic.h>

static const size_t kZSRebindMaxEntries = 8;
static ZSRebindEntry g_entries[8];
static size_t g_entryCount;
static const void *g_selfBase;
static atomic_size_t g_applied;
static BOOL g_registered;

static void zs_rebind_section(const struct section_64 *section, intptr_t slide,
                              const struct nlist_64 *symbols, const char *strings,
                              const uint32_t *indirect, uint32_t indirectCount) {
    const uint32_t start = section->reserved1;
    const size_t slotCount = section->size / sizeof(void *);
    void **slots = (void **)(slide + section->addr);

    vm_address_t pageStart = (vm_address_t)slots & ~((vm_address_t)vm_page_size - 1);
    vm_address_t pageEnd = ((vm_address_t)(slots + slotCount) + vm_page_size - 1) & ~((vm_address_t)vm_page_size - 1);
    BOOL unlocked = NO;

    for (size_t i = 0; i < slotCount; i++) {
        if (start + i >= indirectCount) break;
        uint32_t symIndex = indirect[start + i];
        if (symIndex == INDIRECT_SYMBOL_LOCAL || symIndex == INDIRECT_SYMBOL_ABS ||
            symIndex == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;

        const char *name = strings + symbols[symIndex].n_un.n_strx;
        if (name[0] != '_') continue;

        void *replacement = NULL;
        for (size_t e = 0; e < g_entryCount; e++) {
            if (strcmp(name + 1, g_entries[e].name) == 0) {
                replacement = g_entries[e].replacement;
                break;
            }
        }
        if (!replacement || slots[i] == replacement) continue;

        if (!unlocked) {
            if (vm_protect(mach_task_self(), pageStart, pageEnd - pageStart, FALSE,
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return;
            unlocked = YES;
        }
        slots[i] = replacement;
        atomic_fetch_add(&g_applied, 1);
    }

    if (unlocked) {
        BOOL isConst = (section->flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS;
        vm_protect(mach_task_self(), pageStart, pageEnd - pageStart, FALSE,
                   isConst ? VM_PROT_READ : (VM_PROT_READ | VM_PROT_WRITE));
    }
}

static void zs_rebind_image(const struct mach_header_64 *header, intptr_t slide) {
    if (header->magic != MH_MAGIC_64) return;

    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct segment_command_64 *segments[6];
    int segmentCount = 0;

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                linkedit = segment;
            } else if (strncmp(segment->segname, "__DATA", 6) == 0 && segmentCount < 6) {
                segments[segmentCount++] = segment;
            }
        } else if (command->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)command;
        }
        cursor += command->cmdsize;
    }

    if (!symtab || !dysymtab || !linkedit || dysymtab->nindirectsyms == 0) return;

    const uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkeditBase + dysymtab->indirectsymoff);

    for (int s = 0; s < segmentCount; s++) {
        const struct section_64 *sections =
            (const struct section_64 *)((uintptr_t)segments[s] + sizeof(struct segment_command_64));
        for (uint32_t j = 0; j < segments[s]->nsects; j++) {
            uint32_t type = sections[j].flags & SECTION_TYPE;
            if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
                zs_rebind_section(&sections[j], slide, symbols, strings, indirect, dysymtab->nindirectsyms);
            }
        }
    }
}

static void zs_rebind_image_added(const struct mach_header *header, intptr_t slide) {
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname) return;
    if (info.dli_fbase == g_selfBase) return;
    if (strncmp(info.dli_fname, "/System/", 8) == 0 || strncmp(info.dli_fname, "/usr/", 5) == 0 ||
        strncmp(info.dli_fname, "/private/preboot/", 17) == 0) return;
    zs_rebind_image((const struct mach_header_64 *)header, slide);
}

void zs_rebind_install(const ZSRebindEntry *entries, size_t count) {
    if (!entries || count == 0) return;
    @synchronized ([NSObject class]) {
        for (size_t i = 0; i < count && g_entryCount < kZSRebindMaxEntries; i++) {
            g_entries[g_entryCount++] = entries[i];
        }
        if (g_registered) return;
        g_registered = YES;
        Dl_info self;
        if (dladdr((const void *)&zs_rebind_install, &self)) g_selfBase = self.dli_fbase;
    }
    _dyld_register_func_for_add_image(zs_rebind_image_added);
}

size_t zs_rebind_applied_count(void) {
    return atomic_load(&g_applied);
}
