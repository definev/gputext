// Resolve an OS font family (+ weight/italic) into a TrueType `glyf` sfnt blob
// that GPUFont.parse can consume. One C source, three exported functions, three
// backends selected at compile time:
//
//   Apple (macOS/iOS) — CoreText. Reconstruct an sfnt IN MEMORY from
//     CTFontCopyAvailableTables + CTFontCopyTable. No file access, so it works
//     inside the iOS sandbox where /System/Library/Fonts is unreadable.
//   Android           — dlopen(libandroid) + AFontMatcher (NDK API 29+); read
//     the matched file. Below 29 (our minSdk is 26) fall back to /system/fonts.
//   other             — stub returning NULL; the feature is a graceful no-op.
//
// CoreText and the NDK font APIs are both plain C, so there is no Objective-C or
// Java/Kotlin here. NULL is the single "unavailable" signal for every failure
// (missing font, CFF-only, blocked table, unsupported OS); the Dart layer turns
// it into a null return, never a throw.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define GPUTEXT_EXPORT __declspec(dllexport)
#else
#define GPUTEXT_EXPORT __attribute__((visibility("default")))
#endif

// ---------------------------------------------------------------------------
// Apple: CoreText sfnt reconstruction.
// ---------------------------------------------------------------------------
#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>

// Required tables for a renderable TrueType face (GPUFont needs the outline +
// metrics + cmap tables; HarfBuzz shapes from the same bytes).
enum {
  TAG_glyf = 0x676c7966,
  TAG_loca = 0x6c6f6361,
  TAG_CFF_ = 0x43464620, // 'CFF ' — PostScript outlines gputext can't render
  TAG_cmap = 0x636d6170,
  TAG_head = 0x68656164,
  TAG_hhea = 0x68686561,
  TAG_hmtx = 0x686d7478,
  TAG_maxp = 0x6d617870,
};

static void be16(uint8_t *p, uint16_t v) {
  p[0] = (uint8_t)(v >> 8);
  p[1] = (uint8_t)v;
}

static void be32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)v;
}

// CSS weight (1..1000) → CoreText weight trait (-1..1), snapped to Apple's
// standard anchor points (kCTFontWeightThin .. kCTFontWeightBlack).
static double ct_weight_trait(int css) {
  if (css <= 100) return -0.80;
  if (css <= 200) return -0.60;
  if (css <= 300) return -0.40;
  if (css <= 400) return 0.00;
  if (css <= 500) return 0.23;
  if (css <= 600) return 0.30;
  if (css <= 700) return 0.40;
  if (css <= 800) return 0.56;
  return 0.62;
}

// Build a CTFont for `family` (NULL → the system UI font), constrained to the
// requested weight/italic traits. CoreText substitutes its best available face
// for an unknown family rather than failing — standard, and better than NULL.
static CTFontRef create_ct_font(CFStringRef family, int weight, int italic) {
  CFMutableDictionaryRef traits = CFDictionaryCreateMutable(
      NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  double w = ct_weight_trait(weight);
  CFNumberRef wn = CFNumberCreate(NULL, kCFNumberDoubleType, &w);
  CFDictionarySetValue(traits, kCTFontWeightTrait, wn);
  CFRelease(wn);
  if (italic) {
    int32_t sym = kCTFontTraitItalic; // symbolic-trait bitmask
    CFNumberRef sn = CFNumberCreate(NULL, kCFNumberSInt32Type, &sym);
    CFDictionarySetValue(traits, kCTFontSymbolicTrait, sn);
    CFRelease(sn);
  }
  CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
      NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(attrs, kCTFontTraitsAttribute, traits);
  CFRelease(traits);

  CTFontRef font = NULL;
  if (family) {
    CFDictionarySetValue(attrs, kCTFontFamilyNameAttribute, family);
    CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(attrs);
    if (desc) {
      font = CTFontCreateWithFontDescriptor(desc, 16.0, NULL);
      CFRelease(desc);
    }
  } else {
    // The system UI font has no stable family name (".SFUI"/".AppleSystemUIFont"
    // vary), so start from the UI font and layer the requested traits onto its
    // descriptor.
    CTFontRef base = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 16.0, NULL);
    if (base) {
      CTFontDescriptorRef baseDesc = CTFontCopyFontDescriptor(base);
      if (baseDesc) {
        CTFontDescriptorRef desc =
            CTFontDescriptorCreateCopyWithAttributes(baseDesc, attrs);
        if (desc) {
          font = CTFontCreateWithFontDescriptor(desc, 16.0, NULL);
          CFRelease(desc);
        }
        CFRelease(baseDesc);
      }
      CFRelease(base);
    }
  }
  CFRelease(attrs);
  return font;
}

// Serialize `count` (tag,data) tables into a self-contained sfnt. Table records
// must be sorted by tag ascending — HarfBuzz binary-searches them. Checksums are
// zeroed: both GPUFont.parse and HarfBuzz read and ignore them.
static uint8_t *assemble_sfnt(const uint32_t *tag, CFDataRef *datas,
                              const uint32_t *len, int count,
                              uint32_t *out_len) {
  // Insertion sort by tag (count is ~10-20). Reorder a parallel index array so
  // data/len stay paired.
  int order[64];
  if (count > 64) return NULL;
  for (int i = 0; i < count; i++) order[i] = i;
  for (int i = 1; i < count; i++) {
    int key = order[i], j = i - 1;
    while (j >= 0 && tag[order[j]] > tag[key]) {
      order[j + 1] = order[j];
      j--;
    }
    order[j + 1] = key;
  }

  uint32_t header = 12u + 16u * (uint32_t)count;
  uint32_t total = header;
  for (int i = 0; i < count; i++) total += (len[i] + 3u) & ~3u;

  uint8_t *buf = (uint8_t *)malloc(total);
  if (!buf) return NULL;

  uint16_t entrySelector = 0, p2 = 1;
  while ((uint32_t)(p2 * 2) <= (uint32_t)count) {
    p2 = (uint16_t)(p2 * 2);
    entrySelector++;
  }
  uint16_t searchRange = (uint16_t)(p2 * 16);
  uint16_t rangeShift = (uint16_t)((uint32_t)count * 16u - searchRange);

  be32(buf, 0x00010000);            // sfnt version = TrueType
  be16(buf + 4, (uint16_t)count);   // numTables
  be16(buf + 6, searchRange);
  be16(buf + 8, entrySelector);
  be16(buf + 10, rangeShift);

  uint32_t off = header;
  for (int i = 0; i < count; i++) {
    int s = order[i];
    uint8_t *rec = buf + 12 + 16 * i;
    be32(rec, tag[s]);
    be32(rec + 4, 0); // checksum (ignored)
    be32(rec + 8, off);
    be32(rec + 12, len[s]);
    memcpy(buf + off, CFDataGetBytePtr(datas[s]), len[s]);
    uint32_t padded = (len[s] + 3u) & ~3u;
    for (uint32_t k = len[s]; k < padded; k++) buf[off + k] = 0;
    off += padded;
  }
  *out_len = total;
  return buf;
}

static uint8_t *reconstruct_sfnt(CTFontRef font, uint32_t *out_len) {
  CFArrayRef tags = CTFontCopyAvailableTables(font, kCTFontTableOptionNoOptions);
  if (!tags) return NULL;
  CFIndex n = CFArrayGetCount(tags);
  if (n <= 0) {
    CFRelease(tags);
    return NULL;
  }

  uint32_t *tag = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)n);
  CFDataRef *datas = (CFDataRef *)malloc(sizeof(CFDataRef) * (size_t)n);
  uint32_t *len = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)n);
  if (!tag || !datas || !len) {
    free(tag);
    free(datas);
    free(len);
    CFRelease(tags);
    return NULL;
  }

  int count = 0, hasGlyf = 0, hasLoca = 0, hasCFF = 0;
  int hasCmap = 0, hasHead = 0, hasHhea = 0, hasHmtx = 0, hasMaxp = 0;
  for (CFIndex i = 0; i < n; i++) {
    CTFontTableTag t =
        (CTFontTableTag)(uintptr_t)CFArrayGetValueAtIndex(tags, i);
    CFDataRef d = CTFontCopyTable(font, t, kCTFontTableOptionNoOptions);
    if (!d) continue; // some system fonts refuse individual tables → skip
    tag[count] = (uint32_t)t;
    datas[count] = d;
    len[count] = (uint32_t)CFDataGetLength(d);
    switch (t) {
      case TAG_glyf: hasGlyf = 1; break;
      case TAG_loca: hasLoca = 1; break;
      case TAG_CFF_: hasCFF = 1; break;
      case TAG_cmap: hasCmap = 1; break;
      case TAG_head: hasHead = 1; break;
      case TAG_hhea: hasHhea = 1; break;
      case TAG_hmtx: hasHmtx = 1; break;
      case TAG_maxp: hasMaxp = 1; break;
      default: break;
    }
    count++;
  }
  CFRelease(tags);

  uint8_t *result = NULL;
  // Require TrueType outlines + the metrics/cmap tables GPUFont.parse reads;
  // reject CFF (gputext has no PostScript-outline path).
  if (hasGlyf && hasLoca && hasCmap && hasHead && hasHhea && hasHmtx &&
      hasMaxp && !hasCFF) {
    result = assemble_sfnt(tag, datas, len, count, out_len);
  }
  for (int i = 0; i < count; i++) CFRelease(datas[i]);
  free(tag);
  free(datas);
  free(len);
  return result;
}

static uint8_t *apple_font_data(const char *family, int weight, int italic,
                                uint32_t *out_len) {
  CTFontRef font;
  if (family) {
    CFStringRef fam =
        CFStringCreateWithCString(NULL, family, kCFStringEncodingUTF8);
    if (!fam) return NULL;
    font = create_ct_font(fam, weight, italic);
    CFRelease(fam);
  } else {
    font = create_ct_font(NULL, weight, italic);
  }
  if (!font) return NULL;
  uint8_t *r = reconstruct_sfnt(font, out_len);
  CFRelease(font);
  return r;
}

// ---------------------------------------------------------------------------
// Android: NDK font matcher (dlsym'd — the API is 29+ and our minSdk is 26).
// ---------------------------------------------------------------------------
#elif defined(__ANDROID__)
#include <android/api-level.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>

typedef struct AFontMatcher AFontMatcher;
typedef struct AFont AFont;
typedef AFontMatcher *(*fn_matcher_create)(void);
typedef void (*fn_matcher_set_style)(AFontMatcher *, uint16_t, bool);
typedef AFont *(*fn_matcher_match)(AFontMatcher *, const char *,
                                   const uint16_t *, uint32_t, uint32_t *);
typedef void (*fn_matcher_destroy)(AFontMatcher *);
typedef const char *(*fn_font_get_path)(const AFont *);
typedef void (*fn_font_close)(AFont *);

static uint8_t *read_file(const char *path, uint32_t *out_len) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return NULL;
  }
  long size = ftell(f);
  if (size <= 0 || fseek(f, 0, SEEK_SET) != 0) {
    fclose(f);
    return NULL;
  }
  uint8_t *buf = (uint8_t *)malloc((size_t)size);
  if (!buf) {
    fclose(f);
    return NULL;
  }
  size_t rd = fread(buf, 1, (size_t)size, f);
  fclose(f);
  if (rd != (size_t)size) {
    free(buf);
    return NULL;
  }
  *out_len = (uint32_t)size;
  return buf;
}

// Resolve via AFontMatcher (API 29+). `family` may be a generic name
// ("sans-serif") or a specific one; the matcher always yields a face, falling
// back to the system default for an unknown name.
static uint8_t *android_match(const char *family, int weight, int italic,
                              uint32_t *out_len) {
  if (android_get_device_api_level() < 29) return NULL;
  void *lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
  if (!lib) return NULL;
  fn_matcher_create create =
      (fn_matcher_create)dlsym(lib, "AFontMatcher_create");
  fn_matcher_set_style set_style =
      (fn_matcher_set_style)dlsym(lib, "AFontMatcher_setStyle");
  fn_matcher_match match = (fn_matcher_match)dlsym(lib, "AFontMatcher_match");
  fn_matcher_destroy destroy =
      (fn_matcher_destroy)dlsym(lib, "AFontMatcher_destroy");
  fn_font_get_path get_path =
      (fn_font_get_path)dlsym(lib, "AFont_getFontFilePath");
  fn_font_close close_font = (fn_font_close)dlsym(lib, "AFont_close");

  uint8_t *result = NULL;
  if (create && set_style && match && destroy && get_path && close_font) {
    AFontMatcher *m = create();
    if (m) {
      int w = weight < 1 ? 1 : (weight > 1000 ? 1000 : weight);
      set_style(m, (uint16_t)w, italic ? true : false);
      const uint16_t text[1] = {0x0041}; // 'A' — match() needs a sample run
      AFont *font = match(m, family, text, 1, NULL);
      if (font) {
        const char *path = get_path(font);
        // .ttc collections carry a face index; v1 unwraps face 0 in Dart, which
        // is correct for the common -Regular case.
        if (path) result = read_file(path, out_len);
        close_font(font);
      }
      destroy(m);
    }
  }
  dlclose(lib);
  return result;
}

static uint8_t *android_font_data(const char *family, int weight, int italic,
                                  uint32_t *out_len) {
  if (family) {
    uint8_t *b = android_match(family, weight, italic, out_len);
    if (b) return b;
    // API 26-28 (or matcher miss): best-effort direct file guess. Deliberately
    // NOT defaulting to Roboto here so a bogus named family stays unresolved.
    char path[256];
    snprintf(path, sizeof(path), "/system/fonts/%s-Regular.ttf", family);
    b = read_file(path, out_len);
    if (b) return b;
    snprintf(path, sizeof(path), "/system/fonts/%s.ttf", family);
    return read_file(path, out_len);
  }
  // Default UI font.
  uint8_t *b = android_match("sans-serif", weight, italic, out_len);
  if (b) return b;
  b = read_file("/system/fonts/Roboto-Regular.ttf", out_len);
  if (b) return b;
  return read_file("/system/fonts/DroidSans.ttf", out_len);
}
#endif

// ---------------------------------------------------------------------------
// Exported C ABI (see system_fonts.dart / the plan).
// ---------------------------------------------------------------------------

GPUTEXT_EXPORT uint8_t *gputext_system_font_data(const char *family, int weight,
                                                 int italic, uint32_t *out_len) {
  if (!family || !out_len) return NULL;
  *out_len = 0;
#if defined(__APPLE__)
  return apple_font_data(family, weight, italic, out_len);
#elif defined(__ANDROID__)
  return android_font_data(family, weight, italic, out_len);
#else
  (void)weight;
  (void)italic;
  return NULL;
#endif
}

GPUTEXT_EXPORT uint8_t *gputext_system_default_font_data(int weight, int italic,
                                                         uint32_t *out_len) {
  if (!out_len) return NULL;
  *out_len = 0;
#if defined(__APPLE__)
  return apple_font_data(NULL, weight, italic, out_len);
#elif defined(__ANDROID__)
  return android_font_data(NULL, weight, italic, out_len);
#else
  (void)weight;
  (void)italic;
  return NULL;
#endif
}

GPUTEXT_EXPORT void gputext_system_font_free(uint8_t *ptr) {
  if (ptr) free(ptr);
}
