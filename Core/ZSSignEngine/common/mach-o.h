#pragma once

typedef int cpu_type_t;
typedef int cpu_subtype_t;
typedef int	vm_prot_t;

#define	CPU_ARCH_MASK				0xff000000
#define CPU_ARCH_ABI64				0x01000000
#define CPU_ARCH_ABI64_32 			0x02000000

#define CPU_TYPE_ANY				 -1
#define CPU_TYPE_VAX				 1
#define	CPU_TYPE_MC680x0			 6
#define	CPU_TYPE_X86				 7
#define CPU_TYPE_I386				CPU_TYPE_X86
#define CPU_TYPE_MIPS				 8
#define CPU_TYPE_MC98000			 10
#define CPU_TYPE_HPPA       		 11
#define CPU_TYPE_ARM				 12
#define CPU_TYPE_MC88000			 13
#define CPU_TYPE_SPARC				 14
#define CPU_TYPE_I860				 15
#define CPU_TYPE_ALPHA				 16
#define CPU_TYPE_POWERPC			 18
#define CPU_TYPE_X86_64				(CPU_TYPE_X86 | CPU_ARCH_ABI64)
#define CPU_TYPE_ARM64  			(CPU_TYPE_ARM | CPU_ARCH_ABI64)
#define CPU_TYPE_ARM64_32   		(CPU_TYPE_ARM | CPU_ARCH_ABI64_32)
#define CPU_TYPE_POWERPC64			(CPU_TYPE_POWERPC | CPU_ARCH_ABI64)

#define CPU_SUBTYPE_MASK	0xff000000
#define CPU_SUBTYPE_LIB64	0x80000000

#define	CPU_SUBTYPE_MULTIPLE			 -1
#define CPU_SUBTYPE_LITTLE_ENDIAN		 0
#define CPU_SUBTYPE_BIG_ENDIAN			 1

#define CPU_SUBTYPE_INTEL(f, m)			((f) + ((m) << 4))

#define	CPU_SUBTYPE_I386_ALL			CPU_SUBTYPE_INTEL(3, 0)
#define CPU_SUBTYPE_386					CPU_SUBTYPE_INTEL(3, 0)
#define CPU_SUBTYPE_486					CPU_SUBTYPE_INTEL(4, 0)
#define CPU_SUBTYPE_486SX				CPU_SUBTYPE_INTEL(4, 8)
#define CPU_SUBTYPE_586					CPU_SUBTYPE_INTEL(5, 0)
#define CPU_SUBTYPE_PENT				CPU_SUBTYPE_INTEL(5, 0)
#define CPU_SUBTYPE_PENTPRO				CPU_SUBTYPE_INTEL(6, 1)
#define CPU_SUBTYPE_PENTII_M3			CPU_SUBTYPE_INTEL(6, 3)
#define CPU_SUBTYPE_PENTII_M5			CPU_SUBTYPE_INTEL(6, 5)
#define CPU_SUBTYPE_CELERON				CPU_SUBTYPE_INTEL(7, 6)
#define CPU_SUBTYPE_CELERON_MOBILE		CPU_SUBTYPE_INTEL(7, 7)
#define CPU_SUBTYPE_PENTIUM_3			CPU_SUBTYPE_INTEL(8, 0)
#define CPU_SUBTYPE_PENTIUM_3_M			CPU_SUBTYPE_INTEL(8, 1)
#define CPU_SUBTYPE_PENTIUM_3_XEON		CPU_SUBTYPE_INTEL(8, 2)
#define CPU_SUBTYPE_PENTIUM_M			CPU_SUBTYPE_INTEL(9, 0)
#define CPU_SUBTYPE_PENTIUM_4			CPU_SUBTYPE_INTEL(10, 0)
#define CPU_SUBTYPE_PENTIUM_4_M			CPU_SUBTYPE_INTEL(10, 1)
#define CPU_SUBTYPE_ITANIUM				CPU_SUBTYPE_INTEL(11, 0)
#define CPU_SUBTYPE_ITANIUM_2			CPU_SUBTYPE_INTEL(11, 1)
#define CPU_SUBTYPE_XEON				CPU_SUBTYPE_INTEL(12, 0)
#define CPU_SUBTYPE_XEON_MP				CPU_SUBTYPE_INTEL(12, 1)

#define CPU_SUBTYPE_INTEL_FAMILY(x)	((x) & 15)
#define CPU_SUBTYPE_INTEL_FAMILY_MAX	15

#define CPU_SUBTYPE_INTEL_MODEL(x)	((x) >> 4)
#define CPU_SUBTYPE_INTEL_MODEL_ALL	0

#define CPU_SUBTYPE_X86_ALL			3
#define CPU_SUBTYPE_X86_64_ALL		3
#define CPU_SUBTYPE_X86_ARCH1		4
#define	CPU_SUBTYPE_X86_64_H  		8

#define CPU_SUBTYPE_ARM_ALL 		0
#define CPU_SUBTYPE_ARM_A500_ARCH 	1
#define CPU_SUBTYPE_ARM_A500 		2
#define CPU_SUBTYPE_ARM_A440 		3
#define CPU_SUBTYPE_ARM_M4 			4
#define CPU_SUBTYPE_ARM_V4T 		5
#define CPU_SUBTYPE_ARM_V6 			6
#define CPU_SUBTYPE_ARM_V5 			7
#define CPU_SUBTYPE_ARM_V5TEJ 		7
#define CPU_SUBTYPE_ARM_XSCALE 		8
#define CPU_SUBTYPE_ARM_V7 			9
#define CPU_SUBTYPE_ARM_V7S 		11
#define CPU_SUBTYPE_ARM_V7K 		12
#define CPU_SUBTYPE_ARM_V8 			13
#define CPU_SUBTYPE_ARM_V6M 		14
#define CPU_SUBTYPE_ARM_V7M 		15
#define CPU_SUBTYPE_ARM_V7EM 		16

#define CPU_SUBTYPE_ARM64_ALL 		0
#define CPU_SUBTYPE_ARM64_V8 		1
#define CPU_SUBTYPE_ARM64E 			2
#define CPU_SUBTYPE_ARM64_32_V8		1

#define FAT_MAGIC 		0xcafebabe
#define FAT_CIGAM 		0xbebafeca

#define MH_MAGIC 		0xfeedface
#define MH_CIGAM 		0xcefaedfe
#define MH_MAGIC_64 	0xfeedfacf
#define MH_CIGAM_64 	0xcffaedfe

#define MH_OBJECT 		0x1
#define MH_EXECUTE 		0x2
#define MH_FVMLIB 		0x3
#define MH_CORE 		0x4
#define MH_PRELOAD 		0x5
#define MH_DYLIB 		0x6
#define MH_DYLINKER 	0x7
#define MH_BUNDLE 		0x8
#define MH_DYLIB_STUB   0x9
#define MH_DSYM         0xa
#define MH_KEXT_BUNDLE  0xb

#define	MH_NOUNDEFS					0x00000001
#define	MH_INCRLINK					0x00000002
#define MH_DYLDLINK					0x00000004
#define MH_BINDATLOAD				0x00000008
#define MH_PREBOUND					0x00000010
#define MH_SPLIT_SEGS               0x00000020
#define MH_LAZY_INIT                0x00000040
#define MH_TWOLEVEL                 0x00000080
#define MH_FORCE_FLAT               0x00000100
#define MH_NOMULTIDEFS              0x00000200
#define MH_NOFIXPREBINDING          0x00000400
#define MH_PREBINDABLE              0x00000800
#define MH_ALLMODSBOUND             0x00001000
#define MH_SUBSECTIONS_VIA_SYMBOLS  0x00002000
#define MH_CANONICAL                0x00004000
#define MH_WEAK_DEFINES             0x00008000
#define MH_BINDS_TO_WEAK            0x00010000
#define MH_ALLOW_STACK_EXECUTION    0x00020000
#define MH_ROOT_SAFE                0x00040000
#define MH_SETUID_SAFE              0x00080000
#define MH_NO_REEXPORTED_DYLIBS     0x00100000
#define MH_PIE                      0x00200000
#define MH_DEAD_STRIPPABLE_DYLIB    0x00400000
#define MH_HAS_TLV_DESCRIPTORS      0x00800000
#define MH_NO_HEAP_EXECUTION        0x01000000
#define MH_APP_EXTENSION_SAFE       0x02000000

#define LC_SEGMENT 					0x00000001
#define LC_SYMTAB 					0x00000002
#define LC_SYMSEG 					0x00000003
#define LC_THREAD 					0x00000004
#define LC_UNIXTHREAD 				0x00000005
#define LC_LOADFVMLIB 				0x00000006
#define LC_IDFVMLIB 				0x00000007
#define LC_IDENT 					0x00000008
#define LC_FVMFILE 					0x00000009
#define LC_PREPAGE 					0x0000000a
#define LC_DYSYMTAB 				0x0000000b
#define LC_LOAD_DYLIB 				0x0000000c
#define LC_ID_DYLIB 				0x0000000d
#define LC_LOAD_DYLINKER 			0x0000000e
#define LC_ID_DYLINKER 				0x0000000f
#define LC_PREBOUND_DYLIB 			0x00000010
#define LC_ROUTINES                 0x00000011
#define LC_SUB_FRAMEWORK            0x00000012
#define LC_SUB_UMBRELLA             0x00000013
#define LC_SUB_CLIENT               0x00000014
#define LC_SUB_LIBRARY              0x00000015
#define LC_TWOLEVEL_HINTS           0x00000016
#define LC_PREBIND_CKSUM            0x00000017
#define LC_LOAD_WEAK_DYLIB          0x80000018
#define LC_SEGMENT_64               0x00000019
#define LC_ROUTINES_64              0x0000001A
#define LC_UUID                     0x0000001B
#define LC_RPATH                    0x8000001C
#define LC_CODE_SIGNATURE           0x0000001D
#define LC_SEGMENT_SPLIT_INFO       0x0000001E
#define LC_REEXPORT_DYLIB           0x8000001F
#define LC_LAZY_LOAD_DYLIB          0x00000020
#define LC_ENCRYPTION_INFO          0x00000021
#define LC_DYLD_INFO                0x00000022
#define LC_DYLD_INFO_ONLY           0x80000022
#define LC_LOAD_UPWARD_DYLIB        0x80000023
#define LC_VERSION_MIN_MACOSX       0x00000024
#define LC_VERSION_MIN_IPHONEOS     0x00000025
#define LC_FUNCTION_STARTS          0x00000026
#define LC_DYLD_ENVIRONMENT         0x00000027
#define LC_MAIN                     0x80000028
#define LC_DATA_IN_CODE             0x00000029
#define LC_SOURCE_VERSION           0x0000002A
#define LC_DYLIB_CODE_SIGN_DRS      0x0000002B
#define LC_ENCRYPTION_INFO_64       0x0000002C
#define LC_LINKER_OPTION            0x0000002D
#define LC_LINKER_OPTIMIZATION_HINT 0x0000002E
#define LC_VERSION_MIN_TVOS         0x0000002F
#define LC_VERSION_MIN_WATCHOS      0x00000030

#define	SG_HIGHVM	0x00000001

#define	SG_FVMLIB	0x00000002

#define	SG_NORELOC	0x00000004

#define SG_PROTECTED_VERSION_1  0x00000008

#define SECTION_TYPE            0x000000ff
#define SECTION_ATTRIBUTES      0xffffff00

#define S_REGULAR                              0x00
#define S_ZEROFILL                             0x01
#define S_CSTRING_LITERALS                     0x02
#define S_4BYTE_LITERALS                       0x03
#define S_8BYTE_LITERALS                       0x04
#define S_LITERAL_POINTERS                     0x05
#define S_NON_LAZY_SYMBOL_POINTERS             0x06
#define S_LAZY_SYMBOL_POINTERS                 0x07
#define S_SYMBOL_STUBS                         0x08
#define S_MOD_INIT_FUNC_POINTERS               0x09
#define S_MOD_TERM_FUNC_POINTERS               0x0a
#define S_COALESCED                            0x0b
#define S_GB_ZEROFILL                          0x0c
#define S_INTERPOSING                          0x0d
#define S_16BYTE_LITERALS                      0x0e
#define S_DTRACE_DOF                           0x0f
#define S_LAZY_DYLIB_SYMBOL_POINTERS           0x10
#define S_THREAD_LOCAL_REGULAR                 0x11
#define S_THREAD_LOCAL_ZEROFILL                0x12
#define S_THREAD_LOCAL_VARIABLES               0x13
#define S_THREAD_LOCAL_VARIABLE_POINTERS       0x14
#define S_THREAD_LOCAL_INIT_FUNCTION_POINTERS  0x15

#define S_ATTR_PURE_INSTRUCTIONS    0x80000000
#define S_ATTR_NO_TOC               0x40000000
#define S_ATTR_STRIP_STATIC_SYMS    0x20000000
#define S_ATTR_NO_DEAD_STRIP        0x10000000
#define S_ATTR_LIVE_SUPPORT         0x08000000
#define S_ATTR_SELF_MODIFYING_CODE  0x04000000
#define S_ATTR_DEBUG                0x02000000
#define S_ATTR_SOME_INSTRUCTIONS    0x00000400
#define S_ATTR_EXT_RELOC            0x00000200
#define S_ATTR_LOC_RELOC            0x00000100

#pragma pack(push, 1)

struct fat_header
{
	uint32_t magic;
	uint32_t nfat_arch;
};

struct fat_arch
{
	cpu_type_t cputype;
	cpu_subtype_t cpusubtype;
	uint32_t offset;
	uint32_t size;
	uint32_t align;
};

struct mach_header
{
	uint32_t magic;
	cpu_type_t cputype;
	cpu_subtype_t cpusubtype;
	uint32_t filetype;
	uint32_t ncmds;
	uint32_t sizeofcmds;
	uint32_t flags;
};

struct mach_header_64
{
	uint32_t magic;
	cpu_type_t cputype;
	cpu_subtype_t cpusubtype;
	uint32_t filetype;
	uint32_t ncmds;
	uint32_t sizeofcmds;
	uint32_t flags;
	uint32_t reserved;
};

struct load_command
{
	uint32_t cmd;
	uint32_t cmdsize;
};

struct uuid_command {
  uint32_t cmd;
  uint32_t cmdsize;
  uint8_t uuid[16];
};

struct entry_point_command {
  uint32_t cmd;
  uint32_t cmdsize;
  uint64_t entryoff;
  uint64_t stacksize;
};

struct codesignature_command {
	uint32_t cmd;
	uint32_t cmdsize;
	uint32_t dataoff;
	uint32_t datasize;
};

struct encryption_info_command {
    uint32_t cmd;
    uint32_t cmdsize;
    uint32_t cryptoff;
    uint32_t cryptsize;
    uint32_t cryptid;
};

struct encryption_info_command_64
{
	uint32_t cmd;
	uint32_t cmdsize;
	uint32_t cryptoff;
	uint32_t cryptsize;
	uint32_t cryptid;
	uint32_t pad;
};

struct segment_command {
	uint32_t	cmd;
	uint32_t	cmdsize;
	char		segname[16];
	uint32_t	vmaddr;
	uint32_t	vmsize;
	uint32_t	fileoff;
	uint32_t	filesize;
	vm_prot_t	maxprot;
	vm_prot_t	initprot;
	uint32_t	nsects;
	uint32_t	flags;
};

struct segment_command_64 {
	uint32_t	cmd;
	uint32_t	cmdsize;
	char		segname[16];
	uint64_t	vmaddr;
	uint64_t	vmsize;
	uint64_t	fileoff;
	uint64_t	filesize;
	vm_prot_t	maxprot;
	vm_prot_t	initprot;
	uint32_t	nsects;
	uint32_t	flags;
};

struct section {
	char		sectname[16];
	char		segname[16];
	uint32_t	addr;
	uint32_t	size;
	uint32_t	offset;
	uint32_t	align;
	uint32_t	reloff;
	uint32_t	nreloc;
	uint32_t	flags;
	uint32_t	reserved1;
	uint32_t	reserved2;
};

struct section_64 {
	char		sectname[16];
	char		segname[16];
	uint64_t	addr;
	uint64_t	size;
	uint32_t	offset;
	uint32_t	align;
	uint32_t	reloff;
	uint32_t	nreloc;
	uint32_t	flags;
	uint32_t	reserved1;
	uint32_t	reserved2;
	uint32_t	reserved3;
};

union lc_str {
	uint32_t	offset;
};

struct dylib {
    union lc_str  	name;
    uint32_t 		timestamp;
    uint32_t 		current_version;
    uint32_t 		compatibility_version;
};

struct dylib_command {
	uint32_t		cmd;
	uint32_t		cmdsize;
	struct dylib	dylib;
};

#pragma pack(pop)

enum eCSFLAGS
{
	CSMAGIC_REQUIREMENT = 0xfade0c00,
	CSMAGIC_REQUIREMENTS = 0xfade0c01,
	CSMAGIC_CODEDIRECTORY = 0xfade0c02,
	CSMAGIC_EMBEDDED_SIGNATURE = 0xfade0cc0,
	CSMAGIC_EMBEDDED_SIGNATURE_OLD = 0xfade0b02,
	CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xfade7171,
	CSMAGIC_EMBEDDED_DER_ENTITLEMENTS = 0xfade7172,
	CSMAGIC_DETACHED_SIGNATURE = 0xfade0cc1,
	CSMAGIC_BLOBWRAPPER = 0xfade0b01,
	CS_SUPPORTSSCATTER = 0x20100,
	CS_SUPPORTSTEAMID = 0x20200,
	CS_SUPPORTSCODELIMIT64 = 0x20300,
	CS_SUPPORTSEXECSEG = 0x20400,
	CSSLOT_CODEDIRECTORY = 0,
	CSSLOT_INFOSLOT = 1,
	CSSLOT_REQUIREMENTS = 2,
	CSSLOT_RESOURCEDIR = 3,
	CSSLOT_APPLICATION = 4,
	CSSLOT_ENTITLEMENTS = 5,
	CSSLOT_DER_ENTITLEMENTS = 7,
	CSSLOT_ALTERNATE_CODEDIRECTORIES = 0x1000,
	CSSLOT_ALTERNATE_CODEDIRECTORY_MAX = 5,
	CSSLOT_ALTERNATE_CODEDIRECTORY_LIMIT = CSSLOT_ALTERNATE_CODEDIRECTORIES + CSSLOT_ALTERNATE_CODEDIRECTORY_MAX,
	CSSLOT_SIGNATURESLOT = 0x10000,
	CSSLOT_IDENTIFICATIONSLOT = 0x10001,
	CSSLOT_TICKETSLOT = 0x10002,
	CSTYPE_INDEX_REQUIREMENTS = 0x00000002,
	CSTYPE_INDEX_ENTITLEMENTS = 0x00000005,
	CS_HASHTYPE_SHA1 = 1,
	CS_HASHTYPE_SHA256 = 2,
	CS_HASHTYPE_SHA256_TRUNCATED = 3,
	CS_HASHTYPE_SHA384 = 4,
	CS_SHA1_LEN = 20,
	CS_SHA256_LEN = 32,
	CS_SHA256_TRUNCATED_LEN = 20,
	CS_CDHASH_LEN = 20,
	CS_HASH_MAX_SIZE = 48,
	CS_EXECSEG_MAIN_BINARY = 0x1,
	CS_EXECSEG_ALLOW_UNSIGNED = 0x10,

	CS_SIGNER_TYPE_UNKNOWN = 0,
	CS_SIGNER_TYPE_LEGACYVPN = 5,

	CS_SEC_CODESIGNATURE_ADHOC = 0x0002,
};

#pragma pack(push, 1)

struct CS_BlobIndex {
	uint32_t type;
	uint32_t offset;
};

struct CS_SuperBlob {
	uint32_t magic;
	uint32_t length;
	uint32_t count;

};

struct CS_CodeDirectory {
	uint32_t magic;
	uint32_t length;
	uint32_t version;
	uint32_t flags;
	uint32_t hashOffset;
	uint32_t identOffset;
	uint32_t nSpecialSlots;
	uint32_t nCodeSlots;
	uint32_t codeLimit;
	uint8_t hashSize;
	uint8_t hashType;
	uint8_t spare1;
	uint8_t	pageSize;
	uint32_t spare2;

	uint32_t scatterOffset;

	uint32_t teamOffset;

	uint32_t spare3;
	uint64_t codeLimit64;

	uint64_t execSegBase;
	uint64_t execSegLimit;
	uint64_t execSegFlags;

};

struct CS_Entitlement {
	uint32_t magic;
	uint32_t length;
};

struct CS_GenericBlob {
	uint32_t magic;
	uint32_t length;
};

struct CS_Scatter {
	uint32_t count;
	uint32_t base;
	uint64_t targetOffset;
	uint64_t spare;
};

#pragma pack(pop)
