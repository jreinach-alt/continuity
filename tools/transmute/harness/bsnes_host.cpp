// bsnes_host.cpp — Spike T2.0 P1 headless bsnes runner.
//
// Drives the pinned bsnes libretro core (tools/transmute/vendor/bsnes,
// SerializerVersion "115.1", fastPPU=true) headless: boot a ROM, run
// frames, and save/load byte-compatible `.bst` save states. The `.bst`
// container (12-byte header + RLE<1> serializer payload [+ RLE<2>
// preview]) and the RLE<1> codec are reproduced exactly from the
// user-facing desktop path (target-bsnes/program/states.cpp,
// nall/encode/rle.hpp @ pin) so states written here are the same bytes
// bsnes itself writes, and states written by bsnes load here.
//
// This is the "custom minimal runner over the libretro build" P1 choice
// (spec P1): libretro is the headless boundary bsnes already ships;
// retro_serialize returns the raw System::serialize() payload, so the
// only thing we add on top is the desktop container framing.
//
// Desktop-tier x86_64 tooling — never shipped to a device, src/**
// untouched. Build: see build_bsnes_host.sh (cc -std=c++17, -ldl).
//
// Commands (exit 0 ok / 1 error / 3 state rejected):
//   save   <core.so> <rom> <out.bst> [--frames N]
//   reload <core.so> <rom> <in.bst> <out.bst> [--frames M]
//   check  <core.so> <rom> <in.bst>
//
//   save   : fresh core -> load rom -> run N frames -> write .bst.
//   reload : fresh core -> load rom -> load .bst (exit 3 if rejected)
//            -> run M frames -> write .bst.  (round-trip via a fresh core)
//   check  : fresh core -> load rom -> load .bst; exit 0 accepted /
//            3 rejected. (corrupted-state oracle for control C3)

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <dlfcn.h>

#include "libretro.h"

// ---------------------------------------------------------------------------
// nall RLE<1> (S=1, M=4), transcribed byte-for-byte from
// nall/encode/rle.hpp + nall/decode/rle.hpp @ pin 7d5aa1e. Verified against
// the desktop container by (a) bst_dump decoding our output and (b) the real
// bsnes core loading it.
// ---------------------------------------------------------------------------
static std::vector<uint8_t> rle_encode(const uint8_t* in, size_t n) {
  std::vector<uint8_t> out;
  for (int byte = 0; byte < 8; byte++) out.push_back((uint8_t)(n >> (byte * 8)));
  size_t base = 0, skip = 0;
  auto flush = [&]() {
    out.push_back((uint8_t)(skip - 1));
    do { out.push_back(in[base]); base += 1; } while (--skip);
  };
  while (base + skip < n) {
    size_t same = 1;
    for (size_t off = base + skip + 1; off < n; off++) {
      if (in[off] != in[base + skip]) break;
      if (++same == 127 + 4) break;
    }
    if (same < 4) {
      if (++skip == 128) flush();
    } else {
      if (skip) flush();
      out.push_back((uint8_t)(128 | (same - 4)));
      out.push_back(in[base]);
      base += same;
    }
  }
  if (skip) flush();
  return out;
}

static bool rle_decode(const uint8_t* in, size_t n, std::vector<uint8_t>& out) {
  size_t pos = 0;
  auto load = [&]() -> uint8_t { return pos < n ? in[pos++] : 0; };
  uint64_t size = 0;
  for (int byte = 0; byte < 8; byte++) size |= (uint64_t)load() << (byte * 8);
  out.assign(size, 0);
  size_t base = 0;
  auto write = [&](uint8_t v) { if (base < size) out[base++] = v; };
  while (base < size) {
    if (pos >= n) return false;  // stream truncated before target size
    uint8_t byte = load();
    if (byte < 128) {
      int count = byte + 1;
      while (count--) write(load());
    } else {
      uint8_t value = load();
      int count = (byte & 127) + 4;
      while (count--) write(value);
    }
  }
  return true;
}

static const uint32_t BST_SIGNATURE = 0x5a220000u;  // Program::State::Signature

static bool read_file(const std::string& path, std::vector<uint8_t>& out) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return false;
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  out.resize(sz > 0 ? (size_t)sz : 0);
  size_t got = out.empty() ? 0 : fread(out.data(), 1, out.size(), f);
  fclose(f);
  return got == out.size();
}

static bool write_file(const std::string& path, const std::vector<uint8_t>& d) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) return false;
  size_t put = d.empty() ? 0 : fwrite(d.data(), 1, d.size(), f);
  fclose(f);
  return put == d.size();
}

// Wrap a raw serializer payload in the desktop .bst container.
static std::vector<uint8_t> bst_wrap(const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> rle = rle_encode(payload.data(), payload.size());
  std::vector<uint8_t> file(12);
  auto wl = [&](size_t off, uint32_t v) {
    for (int b = 0; b < 4; b++) file[off + b] = (uint8_t)(v >> (b * 8));
  };
  wl(0, BST_SIGNATURE);
  wl(4, (uint32_t)rle.size());
  wl(8, 0);  // no preview (headless: no video frame captured)
  file.insert(file.end(), rle.begin(), rle.end());
  return file;
}

// Unwrap a .bst container back to the raw serializer payload.
static bool bst_unwrap(const std::vector<uint8_t>& file,
                       std::vector<uint8_t>& payload) {
  if (file.size() < 12) return false;
  auto rl = [&](size_t off) -> uint32_t {
    return (uint32_t)file[off] | (uint32_t)file[off + 1] << 8 |
           (uint32_t)file[off + 2] << 16 | (uint32_t)file[off + 3] << 24;
  };
  uint32_t sig = rl(0), rle_state = rl(4), rle_preview = rl(8);
  if (sig != BST_SIGNATURE) return false;
  if ((uint64_t)12 + rle_state + rle_preview != file.size()) return false;
  return rle_decode(file.data() + 12, rle_state, payload);
}

// ---------------------------------------------------------------------------
// libretro host
// ---------------------------------------------------------------------------
struct Core {
  void* handle = nullptr;
  void (*retro_init)();
  void (*retro_deinit)();
  void (*set_environment)(retro_environment_t);
  void (*set_video_refresh)(retro_video_refresh_t);
  void (*set_audio_sample)(retro_audio_sample_t);
  void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
  void (*set_input_poll)(retro_input_poll_t);
  void (*set_input_state)(retro_input_state_t);
  bool (*load_game)(const retro_game_info*);
  void (*run)();
  size_t (*serialize_size)();
  bool (*serialize)(void*, size_t);
  bool (*unserialize)(const void*, size_t);
};

static std::string g_tmpdir;

static bool env_cb(unsigned cmd, void* data) {
  switch (cmd) {
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
      return *(const enum retro_pixel_format*)data == RETRO_PIXEL_FORMAT_XRGB8888;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
      *(bool*)data = true; return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
      *(const char**)data = g_tmpdir.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
      auto* v = (retro_variable*)data;
      // Force fastPPU=true, matching the user-facing build's default.
      if (v->key && std::strcmp(v->key, "bsnes_ppu_fast") == 0) {
        v->value = "ON"; return true;
      }
      // Power-on entropy: default to None so states are deterministic and
      // controls compare byte-for-byte. Entropy is an emulator-INTERNAL
      // value (the `random` block), not a format field — the serialized
      // size/layout is identical to an entropy-on state, and unserialize
      // never validates random values, so an entropy=None state is still
      // byte-compatible with the user-facing build. Override with
      // BSNES_ENTROPY=Low|High to exercise entropy-on behaviour.
      if (v->key && std::strcmp(v->key, "bsnes_entropy") == 0) {
        const char* e = getenv("BSNES_ENTROPY");
        v->value = e ? e : "None"; return true;
      }
      return false;  // all other options: leave the core's own default
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
      *(bool*)data = false; return true;
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
      *(unsigned*)data = 0; return true;  // legacy SET_VARIABLES path
    case RETRO_ENVIRONMENT_SET_VARIABLES:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
      return true;
    default:
      return false;
  }
}

// Silent stub AV/input callbacks (headless).
static void cb_video(const void*, unsigned, unsigned, size_t) {}
static void cb_audio(int16_t, int16_t) {}
static size_t cb_audio_batch(const int16_t*, size_t frames) { return frames; }
static void cb_input_poll() {}
static int16_t cb_input_state(unsigned, unsigned, unsigned, unsigned) { return 0; }

static bool load_core(const char* path, Core& c) {
  c.handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!c.handle) { fprintf(stderr, "dlopen: %s\n", dlerror()); return false; }
  auto sym = [&](const char* n) { return dlsym(c.handle, n); };
  c.retro_init = (void(*)())sym("retro_init");
  c.retro_deinit = (void(*)())sym("retro_deinit");
  c.set_environment = (void(*)(retro_environment_t))sym("retro_set_environment");
  c.set_video_refresh = (void(*)(retro_video_refresh_t))sym("retro_set_video_refresh");
  c.set_audio_sample = (void(*)(retro_audio_sample_t))sym("retro_set_audio_sample");
  c.set_audio_sample_batch = (void(*)(retro_audio_sample_batch_t))sym("retro_set_audio_sample_batch");
  c.set_input_poll = (void(*)(retro_input_poll_t))sym("retro_set_input_poll");
  c.set_input_state = (void(*)(retro_input_state_t))sym("retro_set_input_state");
  c.load_game = (bool(*)(const retro_game_info*))sym("retro_load_game");
  c.run = (void(*)())sym("retro_run");
  c.serialize_size = (size_t(*)())sym("retro_serialize_size");
  c.serialize = (bool(*)(void*, size_t))sym("retro_serialize");
  c.unserialize = (bool(*)(const void*, size_t))sym("retro_unserialize");
  return c.retro_init && c.load_game && c.run && c.serialize && c.unserialize;
}

// Bring a fresh core up on a ROM, run `frames` frames.
static bool boot(Core& c, const char* rom, int frames) {
  c.set_environment(env_cb);
  c.set_video_refresh(cb_video);
  c.set_audio_sample(cb_audio);
  c.set_audio_sample_batch(cb_audio_batch);
  c.set_input_poll(cb_input_poll);
  c.set_input_state(cb_input_state);
  c.retro_init();
  retro_game_info game{};
  game.path = rom;
  game.data = nullptr;
  game.size = 0;
  game.meta = nullptr;
  if (!c.load_game(&game)) { fprintf(stderr, "retro_load_game failed\n"); return false; }
  for (int i = 0; i < frames; i++) c.run();
  return true;
}

static bool do_serialize(Core& c, std::vector<uint8_t>& payload) {
  size_t sz = c.serialize_size();
  if (!sz) { fprintf(stderr, "serialize_size == 0\n"); return false; }
  payload.assign(sz, 0);
  if (!c.serialize(payload.data(), sz)) { fprintf(stderr, "serialize failed\n"); return false; }
  return true;
}

static int parse_frames(int argc, char** argv, int deflt) {
  for (int i = 0; i < argc; i++)
    if (std::strcmp(argv[i], "--frames") == 0 && i + 1 < argc)
      return atoi(argv[i + 1]);
  return deflt;
}

int main(int argc, char** argv) {
  const char* env_tmp = getenv("TMPDIR");
  g_tmpdir = env_tmp ? env_tmp : "/tmp";

  if (argc < 3) {
    fprintf(stderr,
      "usage: %s <cmd> <core.so> ...\n"
      "  save   <core.so> <rom> <out.bst> [--frames N]\n"
      "  reload <core.so> <rom> <in.bst> <out.bst> [--frames M]\n"
      "  check  <core.so> <rom> <in.bst>\n", argv[0]);
    return 1;
  }
  std::string cmd = argv[1];
  const char* corepath = argv[2];
  Core c;
  if (!load_core(corepath, c)) return 1;

  if (cmd == "save") {
    if (argc < 5) { fprintf(stderr, "save needs <rom> <out.bst>\n"); return 1; }
    const char* rom = argv[3];
    const char* out = argv[4];
    int frames = parse_frames(argc, argv, 0);
    if (!boot(c, rom, frames)) return 1;
    std::vector<uint8_t> payload;
    if (!do_serialize(c, payload)) return 1;
    if (!write_file(out, bst_wrap(payload))) { fprintf(stderr, "write failed\n"); return 1; }
    return 0;
  }

  if (cmd == "reload" || cmd == "check") {
    if (argc < 5) { fprintf(stderr, "%s needs <rom> <in.bst>\n", cmd.c_str()); return 1; }
    const char* rom = argv[3];
    const char* in = argv[4];
    if (!boot(c, rom, 0)) return 1;
    std::vector<uint8_t> file, payload;
    if (!read_file(in, file)) { fprintf(stderr, "read failed: %s\n", in); return 1; }
    if (!bst_unwrap(file, payload)) { fprintf(stderr, "container rejected\n"); return 3; }
    if (!c.unserialize(payload.data(), payload.size())) {
      fprintf(stderr, "unserialize rejected\n"); return 3;
    }
    if (cmd == "check") return 0;
    // reload: advance and re-save.
    int frames = parse_frames(argc, argv, 0);
    if (argc < 6) { fprintf(stderr, "reload needs <out.bst>\n"); return 1; }
    const char* out = argv[5];
    for (int i = 0; i < frames; i++) c.run();
    std::vector<uint8_t> payload2;
    if (!do_serialize(c, payload2)) return 1;
    if (!write_file(out, bst_wrap(payload2))) { fprintf(stderr, "write failed\n"); return 1; }
    return 0;
  }

  fprintf(stderr, "unknown command: %s\n", cmd.c_str());
  return 1;
}
