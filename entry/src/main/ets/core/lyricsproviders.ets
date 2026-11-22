/**
 * LyricsProviders.ets
 * Chuyển đổi từ:
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LyricsHttp.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LrcRed.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/BiniLyrics.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/BetterLyrics.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/Unison.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/PaxSenix.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LyricsPlus.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/YouTubeLyrics.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/KuGou.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LrcLib.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/Musixmatch.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/Genius.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LyricsRepository.kt
 * - web/app/src/lyrics/http.ts, providers.ts, repository.ts
 *
 * Sử dụng chuẩn API của HarmonyOS NEXT:
 * - `@kit.NetworkKit` (`http.createHttp()`) cho các truy vấn mạng HTTP/HTTPS.
 * - `@kit.CryptoArchitectureKit` / Pure ArkTS SHA-256 HMAC & Base64 cho ký xác thực Musixmatch và giải mã KuGou.
 */

import { http } from '@kit.NetworkKit';
import {
  artistForLyricsSearch,
  forLyricsSearch,
  line,
  LyricLine,
  LYRICS_SOURCES,
  LyricsSourceId,
  sourceById,
  withBackgroundVocals,
} from './lyricsmodel';
import {
  asJsonArray,
  asJsonRecord,
  getNumberField,
  getRecordField,
  getStringField,
  isKugouInstrumentalNotice,
  JsonRecord,
  ParsedLyrics,
  parseEnhancedLrc,
  parseGeniusHtml,
  parseLrc,
  parseLyricsPlus,
  parsePaxSenixTimed,
  parseProvider,
  parseRichSync,
  parseTtml,
  plainLines,
  safeJsonParse,
  stripKugouCredits,
  writeTtml,
} from './lyricsparser';

// ---- Tiện ích mã hóa Base64, UTF-8, URL và HMAC-SHA256 chuẩn ArkTS -------------------------

const BASE64_CHARS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** Mã hóa mảng byte Uint8Array sang chuỗi Base64 (không phụ thuộc btoa của trình duyệt). */
export function encodeBase64Bytes(bytes: Uint8Array): string {
  let result = '';
  const len = bytes.length;
  for (let i = 0; i < len; i += 3) {
    const b0 = bytes[i];
    const b1 = (i + 1 < len) ? bytes[i + 1] : 0;
    const b2 = (i + 2 < len) ? bytes[i + 2] : 0;

    const triplet = (b0 << 16) | (b1 << 8) | b2;
    result += BASE64_CHARS.charAt((triplet >>> 18) & 0x3f);
    result += BASE64_CHARS.charAt((triplet >>> 12) & 0x3f);
    result += (i + 1 < len) ? BASE64_CHARS.charAt((triplet >>> 6) & 0x3f) : '=';
    result += (i + 2 < len) ? BASE64_CHARS.charAt(triplet & 0x3f) : '=';
  }
  return result;
}

/** Giải mã chuỗi Base64 sang mảng byte Uint8Array (không phụ thuộc atob của trình duyệt). */
export function decodeBase64ToBytes(base64: string): Uint8Array {
  const cleaned = base64.replace(/[^A-Za-z0-9+/=]/g, '');
  const out: Array<number> = [];
  for (let i = 0; i < cleaned.length; i += 4) {
    const c0 = BASE64_CHARS.indexOf(cleaned.charAt(i));
    const c1 = BASE64_CHARS.indexOf(cleaned.charAt(i + 1));
    const ch2 = cleaned.charAt(i + 2);
    const ch3 = cleaned.charAt(i + 3);
    const c2 = ch2 === '=' ? 0 : BASE64_CHARS.indexOf(ch2);
    const c3 = ch3 === '=' ? 0 : BASE64_CHARS.indexOf(ch3);
    if (c0 < 0 || c1 < 0) {
      continue;
    }
    const triplet = (c0 << 18) | (c1 << 12) | ((c2 & 0x3f) << 6) | (c3 & 0x3f);
    out.push((triplet >>> 16) & 0xff);
    if (ch2 !== '=' && c2 >= 0) {
      out.push((triplet >>> 8) & 0xff);
    }
    if (ch3 !== '=' && c3 >= 0) {
      out.push(triplet & 0xff);
    }
  }
  return new Uint8Array(out);
}

/** Chuyển chuỗi UTF-8 thành Uint8Array (thuần ArkTS). */
export function encodeUtf8(str: string): Uint8Array {
  const bytes: Array<number> = [];
  for (let i = 0; i < str.length; i++) {
    let code = str.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
      const low = str.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        code = ((code - 0xd800) << 10) + (low - 0xdc00) + 0x10000;
        i++;
      }
    }
    if (code <= 0x7f) {
      bytes.push(code);
    } else if (code <= 0x7ff) {
      bytes.push(0xc0 | (code >>> 6));
      bytes.push(0x80 | (code & 0x3f));
    } else if (code <= 0xffff) {
      bytes.push(0xe0 | (code >>> 12));
      bytes.push(0x80 | ((code >>> 6) & 0x3f));
      bytes.push(0x80 | (code & 0x3f));
    } else {
      bytes.push(0xf0 | (code >>> 18));
      bytes.push(0x80 | ((code >>> 12) & 0x3f));
      bytes.push(0x80 | ((code >>> 6) & 0x3f));
      bytes.push(0x80 | (code & 0x3f));
    }
  }
  return new Uint8Array(bytes);
}

/** Giải mã Uint8Array UTF-8 thành chuỗi string (thuần ArkTS). */
export function decodeUtf8(bytes: Uint8Array): string {
  let out = '';
  let i = 0;
  while (i < bytes.length) {
    const b0 = bytes[i++];
    if ((b0 & 0x80) === 0) {
      out += String.fromCharCode(b0);
    } else if ((b0 & 0xe0) === 0xc0 && i < bytes.length) {
      const b1 = bytes[i++] & 0x3f;
      out += String.fromCharCode(((b0 & 0x1f) << 6) | b1);
    } else if ((b0 & 0xf0) === 0xe0 && i + 1 < bytes.length) {
      const b1 = bytes[i++] & 0x3f;
      const b2 = bytes[i++] & 0x3f;
      out += String.fromCharCode(((b0 & 0x0f) << 12) | (b1 << 6) | b2);
    } else if ((b0 & 0xf8) === 0xf0 && i + 2 < bytes.length) {
      const b1 = bytes[i++] & 0x3f;
      const b2 = bytes[i++] & 0x3f;
      const b3 = bytes[i++] & 0x3f;
      const cp = ((b0 & 0x07) << 18) | (b1 << 12) | (b2 << 6) | b3;
      out += String.fromCodePoint(cp);
    }
  }
  return out;
}

const SHA256_K: Array<number> = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

function rotr32(x: number, n: number): number {
  return (x >>> n) | (x << (32 - n));
}

/** Hàm băm SHA-256 thuần ArkTS (phục vụ HMAC-SHA256 ký request Musixmatch). */
export function sha256Bytes(message: Uint8Array): Uint8Array {
  let h0 = 0x6a09e667;
  let h1 = 0xbb67ae85;
  let h2 = 0x3c6ef372;
  let h3 = 0xa54ff53a;
  let h4 = 0x510e527f;
  let h5 = 0x9b05688c;
  let h6 = 0x1f83d9ab;
  let h7 = 0x5be0cd19;

  const bitLen = message.length * 8;
  const padLen = ((message.length + 9 + 63) & ~63);
  const padded = new Uint8Array(padLen);
  padded.set(message, 0);
  padded[message.length] = 0x80;
  const highBits = Math.floor(bitLen / 0x100000000);
  const lowBits = bitLen >>> 0;
  padded[padLen - 8] = (highBits >>> 24) & 0xff;
  padded[padLen - 7] = (highBits >>> 16) & 0xff;
  padded[padLen - 6] = (highBits >>> 8) & 0xff;
  padded[padLen - 5] = highBits & 0xff;
  padded[padLen - 4] = (lowBits >>> 24) & 0xff;
  padded[padLen - 3] = (lowBits >>> 16) & 0xff;
  padded[padLen - 2] = (lowBits >>> 8) & 0xff;
  padded[padLen - 1] = lowBits & 0xff;

  const w = new Array<number>(64).fill(0);
  for (let offset = 0; offset < padLen; offset += 64) {
    for (let i = 0; i < 16; i++) {
      const idx = offset + i * 4;
      w[i] = ((padded[idx] << 24) | (padded[idx + 1] << 16) | (padded[idx + 2] << 8) | padded[idx + 3]) >>> 0;
    }
    for (let i = 16; i < 64; i++) {
      const s0 = (rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3)) >>> 0;
      const s1 = (rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10)) >>> 0;
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }

    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;
    let f = h5;
    let g = h6;
    let h = h7;

    for (let i = 0; i < 64; i++) {
      const S1 = (rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)) >>> 0;
      const ch = ((e & f) ^ ((~e) & g)) >>> 0;
      const temp1 = (h + S1 + ch + SHA256_K[i] + w[i]) >>> 0;
      const S0 = (rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)) >>> 0;
      const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
      const temp2 = (S0 + maj) >>> 0;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }

    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
    h5 = (h5 + f) >>> 0;
    h6 = (h6 + g) >>> 0;
    h7 = (h7 + h) >>> 0;
  }

  const digest = new Uint8Array(32);
  const words = [h0, h1, h2, h3, h4, h5, h6, h7];
  for (let i = 0; i < 8; i++) {
    const word = words[i];
    digest[i * 4] = (word >>> 24) & 0xff;
    digest[i * 4 + 1] = (word >>> 16) & 0xff;
    digest[i * 4 + 2] = (word >>> 8) & 0xff;
    digest[i * 4 + 3] = word & 0xff;
  }
  return digest;
}

/** Tính chữ ký HMAC-SHA256 trả về mảng byte Uint8Array. */
export function hmacSha256Bytes(keyStr: string, messageStr: string): Uint8Array {
  let keyBytes = encodeUtf8(keyStr);
  const msgBytes = encodeUtf8(messageStr);
  const blockSize = 64;
  if (keyBytes.length > blockSize) {
    keyBytes = sha256Bytes(keyBytes);
  }
  const ipad = new Uint8Array(blockSize);
  const opad = new Uint8Array(blockSize);
  for (let i = 0; i < blockSize; i++) {
    const k = i < keyBytes.length ? keyBytes[i] : 0;
    ipad[i] = k ^ 0x36;
    opad[i] = k ^ 0x5c;
  }
  const innerInput = new Uint8Array(blockSize + msgBytes.length);
  innerInput.set(ipad, 0);
  innerInput.set(msgBytes, blockSize);
  const innerHash = sha256Bytes(innerInput);

  const outerInput = new Uint8Array(blockSize + innerHash.length);
  outerInput.set(opad, 0);
  outerInput.set(innerHash, blockSize);
  return sha256Bytes(outerInput);
}

// ---- LyricsHttp.kt & http.ts (Giao tiếp mạng HTTP cho HarmonyOS NEXT) -----------------------

const DIRECT_TIMEOUT_MS: number = 6000;
const PATIENT_TIMEOUT_MS: number = 15000;
const DEFAULT_USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

export interface LyricsGetOptions {
  headers?: Record<string, string>;
  patient?: boolean;
}

/**
 * Thực hiện HTTP GET trả về chuỗi body hoặc null (không bao giờ ném ngoại lệ ra ngoài).
 * Sử dụng `@kit.NetworkKit` (`http.createHttp()`) chuẩn của HarmonyOS NEXT.
 */
export async function lyricsGet(url: string, options?: LyricsGetOptions): Promise<string | null> {
  const client = http.createHttp();
  try {
    const headerMap: Record<string, string> = {
      'Accept': 'application/json, text/plain, */*',
      'User-Agent': DEFAULT_USER_AGENT,
    };
    if (options !== undefined && options.headers !== undefined) {
      const customKeys = Object.keys(options.headers);
      for (let i = 0; i < customKeys.length; i++) {
        const k = customKeys[i];
        headerMap[k] = options.headers[k];
      }
    }
    const timeout: number = (options !== undefined && options.patient === true)
      ? PATIENT_TIMEOUT_MS
      : DIRECT_TIMEOUT_MS;

    const response = await client.request(url, {
      method: http.RequestMethod.GET,
      header: headerMap,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: timeout,
      readTimeout: timeout,
    });

    if (response.responseCode >= 200 && response.responseCode < 300) {
      if (typeof response.result === 'string') {
        return response.result;
      }
      if (response.result !== null && response.result !== undefined) {
        return JSON.stringify(response.result);
      }
    }
    return null;
  } catch (_e) {
    return null;
  } finally {
    client.destroy();
  }
}

/** Bộ tham số query, dùng thay object literal vì ArkTS cấm literal không khai báo kiểu. */
export class UrlQuery {
  private keys: Array<string> = [];
  private values: Array<string> = [];

  set(key: string, value: string | number | null | undefined): UrlQuery {
    if (value !== null && value !== undefined && String(value).length > 0) {
      this.keys.push(key);
      this.values.push(String(value));
    }
    return this;
  }

  append(base: string): string {
    if (this.keys.length === 0) {
      return base;
    }
    const queryParts: Array<string> = [];
    for (let i = 0; i < this.keys.length; i++) {
      queryParts.push(`${encodeURIComponent(this.keys[i])}=${encodeURIComponent(this.values[i])}`);
    }
    const sep = base.includes('?') ? '&' : '?';
    return `${base}${sep}${queryParts.join('&')}`;
  }
}

/** Ghép tham số query vào URL, tự động bỏ qua các giá trị null/undefined/rỗng. */
export function urlWith(
  base: string,
  params: UrlQuery | Record<string, string | number | null | undefined>
): string {
  if (params instanceof UrlQuery) {
    return params.append(base);
  }
  const built = new UrlQuery();
  const keys = Object.keys(params);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    built.set(key, params[key]);
  }
  return built.append(base);
}

// ---- Cấu trúc truy vấn chung cho các Lyrics Providers ---------------------------------------

export class LyricsQuery {
  videoId: string;
  title: string;
  artist: string;
  durationMs: number;
  album: string | null;
  isrc: string | null;

  constructor(
    videoId: string,
    title: string,
    artist: string,
    durationMs: number,
    album: string | null = null,
    isrc: string | null = null
  ) {
    this.videoId = videoId;
    this.title = title;
    this.artist = artist;
    this.durationMs = durationMs;
    this.album = album;
    this.isrc = isrc;
  }
}

export type SharedGetFn = (url: string) => Promise<string | null>;

function fromTtml(ttml: string | null): ParsedLyrics | null {
  if (ttml === null || ttml.length === 0) {
    return null;
  }
  const lines = parseTtml(ttml);
  return lines.length > 0 ? new ParsedLyrics(lines, ttml) : null;
}

function fromLines(lines: Array<LyricLine> | null | undefined): ParsedLyrics | null {
  if (lines === null || lines === undefined) {
    return null;
  }
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].text.trim().length > 0) {
      return new ParsedLyrics(lines, null);
    }
  }
  return null;
}

function durationInSeconds(ms: number): number | null {
  return ms > 0 ? Math.floor(ms / 1000) : null;
}

// ---- 1. lrc.red (LrcRed.kt) -----------------------------------------------------------------

const LRC_RED_BASE: string = 'https://lrc.red/';
const ISRC_REGEX: RegExp = /^[A-Z]{2}[A-Z0-9]{3}\d{7}$/;

export function lrcRedDocument(isrc: string | null | undefined): string | null {
  if (isrc === null || isrc === undefined) {
    return null;
  }
  const code = isrc.trim().toUpperCase();
  return (code.length > 0 && ISRC_REGEX.test(code)) ? `${LRC_RED_BASE}s/${code}.ttml` : null;
}

export class LrcRedHit {
  isrc: string | null;
  title: string | null;
  artist: string | null;
  duration: number | null;

  constructor(
    isrc: string | null = null,
    title: string | null = null,
    artist: string | null = null,
    duration: number | null = null
  ) {
    this.isrc = isrc;
    this.title = title;
    this.artist = artist;
    this.duration = duration;
  }
}

const VERSION_WORDS: Array<string> = [
  'live', 'remix', 'remixed', 'mix', 'acoustic', 'unplugged', 'instrumental', 'karaoke', 'cappella', 'acapella',
  'demo', 'edit', 'version', 'cover', 'sped', 'slowed', 'reverb', 'nightcore', 'lofi', 'orchestral', 'extended',
];
const BRACKETED_REGEX: RegExp = /[([][^)\]]*[)\]]/g;
const ARTIST_SEPARATORS_REGEX: RegExp = /\s*(?:,|&|;|\/|\s+and\s+|\s+x\s+|\s+with\s+|\s+feat\.?\s+|\s+ft\.?\s+)\s*/i;

function normalizeForMatch(value: string): string {
  return value
    .normalize('NFD')
    .replace(/\p{Mn}+/gu, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function coreOfTitle(title: string): string {
  const withoutBrackets = title.replace(BRACKETED_REGEX, ' ');
  const dashParts = withoutBrackets.split(' - ');
  const firstPart = dashParts.length > 0 ? normalizeForMatch(dashParts[0]) : '';
  return firstPart.length > 0 ? firstPart : normalizeForMatch(title);
}

function versionWordsOfTitle(title: string): Array<string> {
  const bracketMatches = title.match(BRACKETED_REGEX);
  const bracketText = bracketMatches !== null ? bracketMatches.join(' ') : '';
  const dashIdx = title.indexOf(' - ');
  const tailText = dashIdx >= 0 ? title.slice(dashIdx + 3) : '';
  const tokens = normalizeForMatch(`${bracketText} ${tailText}`).split(' ');
  const out: Array<string> = [];
  for (let i = 0; i < tokens.length; i++) {
    const w = tokens[i];
    if (w.length > 0 && VERSION_WORDS.includes(w) && !out.includes(w)) {
      out.push(w);
    }
  }
  return out;
}

function artistsSetOf(artist: string): Array<string> {
  const parts = artist.split(ARTIST_SEPARATORS_REGEX);
  const out: Array<string> = [];
  for (let i = 0; i < parts.length; i++) {
    const norm = normalizeForMatch(parts[i]);
    if (norm.length > 0 && !out.includes(norm)) {
      out.push(norm);
    }
  }
  return out;
}

function sameStringSet(a: Array<string>, b: Array<string>): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (!b.includes(a[i])) {
      return false;
    }
  }
  return true;
}

/** Chọn kết quả khớp chính xác nhất trên lrc.red theo tên bài, phiên bản, nghệ sĩ và độ dài (sai số <= 3s). */
export function bestLrcRedHit(
  hits: Array<LrcRedHit>,
  title: string,
  artist: string,
  durationMs: number
): LrcRedHit | null {
  const wantedTitle = coreOfTitle(title);
  const wantedVersion = versionWordsOfTitle(title);
  const wantedArtists = artistsSetOf(artist);
  const secs = durationMs / 1000;

  const distance = (hit: LrcRedHit): number => {
    return (durationMs > 0 && hit.duration !== null) ? Math.abs(hit.duration - secs) : 0;
  };

  const passing: Array<LrcRedHit> = [];
  for (let i = 0; i < hits.length; i++) {
    const hit = hits[i];
    if (hit.title === null || lrcRedDocument(hit.isrc) === null) {
      continue;
    }
    if (coreOfTitle(hit.title) !== wantedTitle) {
      continue;
    }
    if (!sameStringSet(versionWordsOfTitle(hit.title), wantedVersion)) {
      continue;
    }
    if (wantedArtists.length > 0) {
      const hitArtists = artistsSetOf(hit.artist !== null ? hit.artist : '');
      let artistMatched = false;
      for (let j = 0; j < hitArtists.length; j++) {
        if (wantedArtists.includes(hitArtists[j])) {
          artistMatched = true;
          break;
        }
      }
      if (!artistMatched) {
        continue;
      }
    }
    if (distance(hit) <= 3) {
      passing.push(hit);
    }
  }

  passing.sort((a: LrcRedHit, b: LrcRedHit): number => distance(a) - distance(b));
  return passing.length > 0 ? passing[0] : null;
}

export async function lrcRed(q: LyricsQuery, get: SharedGetFn): Promise<ParsedLyrics | null> {
  const known = lrcRedDocument(q.isrc);
  if (known !== null) {
    const found = fromTtml(await get(known));
    if (found !== null) {
      return found;
    }
  }
  const searchUrl = urlWith(`${LRC_RED_BASE}search.json`, new UrlQuery().set("q", `${q.title} ${q.artist}`.trim()));
  const rawBody = await lyricsGet(searchUrl);
  const root = asJsonRecord(safeJsonParse(rawBody));
  const rawHits = root !== null ? asJsonArray(getRecordField(root, 'hits')) : null;
  const hits: Array<LrcRedHit> = [];
  if (rawHits !== null) {
    for (let i = 0; i < rawHits.length; i++) {
      const h = asJsonRecord(rawHits[i]);
      if (h !== null) {
        hits.push(new LrcRedHit(
          getStringField(h, 'isrc'),
          getStringField(h, 'title'),
          getStringField(h, 'artist'),
          getNumberField(h, 'duration')
        ));
      }
    }
  }
  const hit = bestLrcRedHit(hits, q.title, q.artist, q.durationMs);
  const url = hit !== null ? lrcRedDocument(hit.isrc) : null;
  if (url !== null && url !== known) {
    return fromTtml(await get(url));
  }
  return null;
}

// ---- 2. BiniLyrics (BiniLyrics.kt) ----------------------------------------------------------

export class BiniHit {
  isrc: string | null;
  lyricsUrl: string | null;

  constructor(isrc: string | null = null, lyricsUrl: string | null = null) {
    this.isrc = isrc;
    this.lyricsUrl = lyricsUrl;
  }
}

export class BiniParsedResult {
  parsed: ParsedLyrics;
  isrc: string | null;

  constructor(parsed: ParsedLyrics, isrc: string | null) {
    this.parsed = parsed;
    this.isrc = isrc;
  }
}

/** Nhận diện mã ghi âm ISRC và URL TTML từ BiniLyrics. */
export async function biniIdentify(q: LyricsQuery): Promise<BiniHit | null> {
  const url: string = (q.isrc !== null && q.isrc.length > 0)
    ? urlWith('https://lyrics-api.binimum.org/', new UrlQuery().set("isrc", q.isrc))
    : urlWith('https://lyrics-api.binimum.org/', new UrlQuery().set("track", q.title).set("artist", q.artist).set("album", q.album).set("duration", durationInSeconds(q.durationMs)));
  const root = asJsonRecord(safeJsonParse(await lyricsGet(url)));
  const results = root !== null ? asJsonArray(getRecordField(root, 'results')) : null;
  if (results === null || results.length === 0) {
    return null;
  }
  const first = asJsonRecord(results[0]);
  if (first === null) {
    return null;
  }
  return new BiniHit(getStringField(first, 'isrc'), getStringField(first, 'lyricsUrl'));
}

export async function bini(
  q: LyricsQuery,
  get: SharedGetFn,
  preIdentified: BiniHit | null
): Promise<BiniParsedResult | null> {
  const found: BiniHit | null = preIdentified !== null ? preIdentified : await biniIdentify(q);
  if (found === null || found.lyricsUrl === null || found.lyricsUrl.length === 0) {
    return null;
  }
  const parsed = fromTtml(await get(found.lyricsUrl));
  if (parsed === null) {
    return null;
  }
  return new BiniParsedResult(parsed, found.isrc);
}

// ---- 3. BetterLyrics (BetterLyrics.kt) ------------------------------------------------------

async function betterLyricsAt(endpoint: string, q: LyricsQuery): Promise<ParsedLyrics | null> {
  const url = urlWith(endpoint, new UrlQuery().set("s", q.title).set("a", q.artist).set("d", durationInSeconds(q.durationMs)).set("al", q.album));
  const body = await lyricsGet(url);
  return body !== null ? parseProvider(body) : null;
}

export async function betterLyrics(q: LyricsQuery): Promise<ParsedLyrics | null> {
  return betterLyricsAt('https://lyrics-api.boidu.dev/getLyrics', q);
}

export async function betterLyricsPortato(q: LyricsQuery): Promise<ParsedLyrics | null> {
  return betterLyricsAt('https://lyrics-api.boidu.dev/qq/getLyrics', q);
}

// ---- 4. Unison (Unison.kt) ------------------------------------------------------------------

export async function unison(q: LyricsQuery): Promise<ParsedLyrics | null> {
  const url = urlWith('https://unison.boidu.dev/lyrics', new UrlQuery().set("song", q.title).set("artist", q.artist).set("album", q.album).set("duration", durationInSeconds(q.durationMs)));
  const root = asJsonRecord(safeJsonParse(await lyricsGet(url)));
  if (root === null || getRecordField(root, 'success') !== true) {
    return null;
  }
  const data = asJsonRecord(getRecordField(root, 'data'));
  if (data === null) {
    return null;
  }
  const rawLyrics = getStringField(data, 'lyrics');
  const text = rawLyrics !== null ? rawLyrics.trim() : '';
  if (text.length === 0) {
    return null;
  }
  const format = getStringField(data, 'format');
  if (format !== null && format.toLowerCase() === 'ttml') {
    return fromTtml(text);
  }
  const syncType = getStringField(data, 'syncType');
  if (syncType !== null && syncType.toLowerCase() === 'plain') {
    return fromLines(plainLines(text));
  }
  const enhanced = parseEnhancedLrc(text);
  return fromLines(enhanced.length > 0 ? enhanced : parseLrc(text));
}

// ---- 5. PaxSenix (PaxSenix.kt) --------------------------------------------------------------

class PaxCandidate {
  id: string;
  title: string;
  artist: string;
  durationMs: number;

  constructor(id: string, title: string, artist: string, durationMs: number) {
    this.id = id;
    this.title = title;
    this.artist = artist;
    this.durationMs = durationMs;
  }
}

class ScoredPaxCandidate {
  parsed: ParsedLyrics;
  score: number;
  distance: number;

  constructor(parsed: ParsedLyrics, score: number, distance: number) {
    this.parsed = parsed;
    this.score = score;
    this.distance = distance;
  }
}

const PAX_ID_KEYS: Array<string> = ['id', 'trackId', 'track_id', 'realId'];
const PAX_TITLE_KEYS: Array<string> = ['name', 'title', 'trackName', 'track_name'];
const PAX_ARTIST_KEYS: Array<string> = ['artistName', 'artist_name'];
const PAX_DURATION_KEYS: Array<string> = ['durationInMillis', 'durationMs', 'duration_ms', 'duration'];

function firstStringFromRecord(o: JsonRecord, keys: Array<string>): string | null {
  for (let i = 0; i < keys.length; i++) {
    const val = getRecordField(o, keys[i]);
    if (typeof val === 'string' && val.trim().length > 0) {
      return val.trim();
    }
    if (typeof val === 'number' && Number.isFinite(val)) {
      return String(val);
    }
  }
  return null;
}

function firstNumberFromRecord(o: JsonRecord, keys: Array<string>): number | null {
  for (let i = 0; i < keys.length; i++) {
    const val = getNumberField(o, keys[i]);
    if (val !== null) {
      return val;
    }
  }
  return null;
}

function normalizeDurationMs(n: number | null): number {
  if (n === null || n <= 0) {
    return 0;
  }
  return n < 10000 ? n * 1000 : n;
}

function extractArtistNames(o: JsonRecord): string | null {
  const artistsVal = getRecordField(o, 'artists') !== undefined
    ? getRecordField(o, 'artists')
    : getRecordField(o, 'artist');
  if (typeof artistsVal === 'string') {
    return artistsVal;
  }
  const arr = asJsonArray(artistsVal);
  if (arr !== null) {
    const names: Array<string> = [];
    for (let i = 0; i < arr.length; i++) {
      const item = arr[i];
      if (typeof item === 'string' && item.trim().length > 0) {
        names.push(item.trim());
      } else {
        const rec = asJsonRecord(item);
        if (rec !== null) {
          const n = firstStringFromRecord(rec, ['name', 'artistName', 'title']);
          if (n !== null) {
            names.push(n);
          }
        }
      }
    }
    return names.length > 0 ? names.join(', ') : null;
  }
  const obj = asJsonRecord(artistsVal);
  if (obj !== null) {
    return firstStringFromRecord(obj, ['name', 'artistName', 'title']);
  }
  return null;
}

function collectPaxCandidates(root: Object | null | undefined, into: Array<PaxCandidate>): Array<PaxCandidate> {
  const arr = asJsonArray(root);
  if (arr !== null) {
    for (let i = 0; i < arr.length; i++) {
      collectPaxCandidates(arr[i], into);
    }
    return into;
  }
  const o = asJsonRecord(root);
  if (o !== null) {
    const attrs = asJsonRecord(getRecordField(o, 'attributes'));
    const details: JsonRecord = attrs !== null ? attrs : o;
    const idFromO = firstStringFromRecord(o, PAX_ID_KEYS);
    const id = idFromO !== null ? idFromO : firstStringFromRecord(details, PAX_ID_KEYS);
    const title = firstStringFromRecord(details, PAX_TITLE_KEYS);
    if (id !== null && title !== null) {
      const artistDirect = firstStringFromRecord(details, PAX_ARTIST_KEYS);
      const artist = artistDirect !== null
        ? artistDirect
        : (extractArtistNames(details) !== null ? (extractArtistNames(details) as string) : '');
      const durationMs = normalizeDurationMs(firstNumberFromRecord(details, PAX_DURATION_KEYS));
      into.push(new PaxCandidate(id, title, artist, durationMs));
    }
    const keys = Object.keys(o);
    for (let i = 0; i < keys.length; i++) {
      collectPaxCandidates(o[keys[i]], into);
    }
  }
  return into;
}

function textMatchScore(candidate: string, wanted: string, exact: number, partial: number): number {
  const c = candidate.toLowerCase().trim();
  const w = wanted.toLowerCase().trim();
  if (c.length === 0 || w.length === 0) {
    return 0;
  }
  if (c === w) {
    return exact;
  }
  return (c.includes(w) || w.includes(c)) ? partial : 0;
}

function bestPaxCandidate(root: Object | null | undefined, q: LyricsQuery): PaxCandidate | null {
  const candidates = collectPaxCandidates(root, []);
  let bestCandidateObj: PaxCandidate | null = null;
  let bestScore: number = -1;

  for (let i = 0; i < candidates.length; i++) {
    const c = candidates[i];
    let score = textMatchScore(c.title, q.title, 20, 10) + textMatchScore(c.artist, q.artist, 15, 5);
    if (q.durationMs > 0 && c.durationMs > 0) {
      const diff = Math.abs(c.durationMs - q.durationMs);
      score += diff < 3000 ? 10 : (diff < 10000 ? 5 : 0);
    }
    if (bestCandidateObj === null || score > bestScore) {
      bestCandidateObj = c;
      bestScore = score;
    }
  }
  return (bestCandidateObj !== null && bestScore >= 10) ? bestCandidateObj : null;
}

function paxResponse(raw: string | null): ParsedLyrics | null {
  if (raw === null) {
    return null;
  }
  const timed = fromLines(parsePaxSenixTimed(raw));
  return timed !== null ? timed : parseProvider(raw);
}

let cachedAppleWebToken: string | null = null;
let cachedAppleWebTokenAt: number = 0;

async function fetchAppleWebToken(): Promise<string | null> {
  if (cachedAppleWebToken !== null && Date.now() - cachedAppleWebTokenAt < 3600000) {
    return cachedAppleWebToken;
  }
  const html = await lyricsGet('https://music.apple.com/us/browse');
  if (html === null) {
    return null;
  }
  const scriptMatch = /src="(\/assets\/index-legacy-[^"]+\.js|\/assets\/index~[^"]+\.js)"/i.exec(html);
  if (scriptMatch === null || scriptMatch[1] === undefined) {
    return null;
  }
  const js = await lyricsGet(`https://music.apple.com${scriptMatch[1]}`);
  if (js === null) {
    return null;
  }
  const tokenMatch = /eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6I([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)/.exec(js);
  if (tokenMatch !== null) {
    cachedAppleWebToken = tokenMatch[0];
    cachedAppleWebTokenAt = Date.now();
    return cachedAppleWebToken;
  }
  return null;
}

export async function paxSenix(q: LyricsQuery): Promise<ParsedLyrics | null> {
  const token = await fetchAppleWebToken();
  if (token === null) {
    return null;
  }
  const searchUrl = urlWith('https://amp-api.music.apple.com/v1/catalog/us/search', new UrlQuery().set("term", `${q.title} ${q.artist}`).set("types", 'songs').set("limit", 10).set("l", 'en-US'));
  const searchBody = await lyricsGet(searchUrl, {
    headers: {
      'Authorization': `Bearer ${token}`,
      'Origin': 'https://music.apple.com',
      'Referer': 'https://music.apple.com/',
    },
  });
  const candidate = bestPaxCandidate(safeJsonParse(searchBody), q);
  if (candidate === null) {
    return null;
  }
  const lyricsUrl = urlWith('https://lyrics.paxsenix.org/apple-music/lyrics', new UrlQuery().set("id", candidate.id).set("ttml", 'true'));
  return paxResponse(await lyricsGet(lyricsUrl));
}

function paxApiGet(path: string, params: UrlQuery, key: string): Promise<string | null> {
  const cleanKey = key.replace(/^Bearer\s+/i, '').trim();
  const headers: Record<string, string> = {};
  headers['Authorization'] = `Bearer ${cleanKey}`;
  const options: LyricsGetOptions = {
    patient: true,
    headers: headers,
  };
  return lyricsGet(urlWith(`https://api.paxsenix.org/${path}`, params), options);
}

async function paxGeneric(q: LyricsQuery, key: string): Promise<ParsedLyrics | null> {
  const raw = await paxApiGet('lyrics/lrcget', new UrlQuery().set('q', `${q.title} ${q.artist}`), key);
  const root = asJsonRecord(safeJsonParse(raw));
  const documents = root !== null ? asJsonArray(getRecordField(root, 'lyrics')) : null;
  if (documents === null || documents.length === 0) {
    return paxResponse(raw);
  }
  const scored: Array<ScoredPaxCandidate> = [];
  for (let i = 0; i < documents.length; i++) {
    const doc = documents[i];
    if (doc === null || doc === undefined) {
      continue;
    }
    const parsed = paxResponse(JSON.stringify(doc));
    if (parsed === null) {
      continue;
    }
    const cands = collectPaxCandidates([doc], []);
    const c = cands.length > 0 ? cands[0] : null;
    const score = c !== null
      ? textMatchScore(c.title, q.title, 20, 10) + textMatchScore(c.artist, q.artist, 15, 5)
      : 0;
    let last: number = 0;
    for (let j = 0; j < parsed.lines.length; j++) {
      const l = parsed.lines[j];
      const su = l.sungUntilMs !== null ? l.sungUntilMs : 0;
      const we = l.words.length > 0 ? l.words[l.words.length - 1].endMs : 0;
      const lineMax = Math.max(l.timeMs, su, we);
      if (lineMax > last) {
        last = lineMax;
      }
    }
    const distance = q.durationMs > 0 ? Math.abs(last - q.durationMs) : 0;
    scored.push(new ScoredPaxCandidate(parsed, score, distance));
  }
  scored.sort((a: ScoredPaxCandidate, b: ScoredPaxCandidate): number => {
    if (b.score !== a.score) {
      return b.score - a.score;
    }
    return a.distance - b.distance;
  });
  return scored.length > 0 ? scored[0].parsed : null;
}

export async function paxSenixSpotify(q: LyricsQuery, key: string): Promise<ParsedLyrics | null> {
  if (key.trim().length === 0) {
    return null;
  }
  const searchRaw = await paxApiGet('spotify/search', new UrlQuery().set('q', `${q.title} ${q.artist}`), key);
  const candidate = bestPaxCandidate(safeJsonParse(searchRaw), q);
  if (candidate !== null) {
    const direct = paxResponse(await paxApiGet('lyrics/spotify', new UrlQuery().set('id', candidate.id), key));
    if (direct !== null) {
      return direct;
    }
  }
  return paxGeneric(q, key);
}

export async function paxSenixMusixmatch(q: LyricsQuery, key: string): Promise<ParsedLyrics | null> {
  if (key.trim().length === 0) {
    return null;
  }
  const raw = await paxApiGet(
    'lyrics/musixmatch',
    new UrlQuery().set('t', q.title).set('a', q.artist).set('d', String(Math.floor(q.durationMs / 1000))),
    key
  );
  const found = paxResponse(raw);
  return found !== null ? found : paxGeneric(q, key);
}

// ---- 6. LyricsPlus (LyricsPlus.kt) ----------------------------------------------------------

const LYRICS_PLUS_MIRRORS: Array<string> = [
  'https://lyricsplus.prjktla.my.id',
  'https://lyricsplus.binimum.org',
];
let lastGoodMirror: string | null = null;

export async function lyricsPlus(q: LyricsQuery): Promise<ParsedLyrics | null> {
  const hosts: Array<string> = [];
  if (lastGoodMirror !== null) {
    hosts.push(lastGoodMirror);
  }
  for (let i = 0; i < LYRICS_PLUS_MIRRORS.length; i++) {
    if (LYRICS_PLUS_MIRRORS[i] !== lastGoodMirror) {
      hosts.push(LYRICS_PLUS_MIRRORS[i]);
    }
  }

  return new Promise<ParsedLyrics | null>((resolve) => {
    let pending = hosts.length;
    let done = false;
    for (let i = 0; i < hosts.length; i++) {
      const host = hosts[i];
      const url = urlWith(`${host}/v2/lyrics/get`, new UrlQuery().set("title", q.title).set("artist", q.artist).set("duration", durationInSeconds(q.durationMs)).set("album", q.album).set("isrc", q.isrc));
      lyricsGet(url).then((raw: string | null) => {
        const body = safeJsonParse(raw);
        const lines = body !== null ? parseLyricsPlus(body) : [];
        if (!done && lines.length > 0) {
          done = true;
          lastGoodMirror = host;
          resolve(new ParsedLyrics(lines, null));
        }
        pending--;
        if (pending === 0 && !done) {
          resolve(null);
        }
      });
    }
  });
}

// ---- 7. KuGou (KuGou.kt) --------------------------------------------------------------------

function stripParenthetical(s: string): string {
  const cleaned = s.replace(/[(（].*?[)）]/g, '').trim();
  return cleaned.length > 0 ? cleaned : s;
}

class KugouSongItem {
  hash: string;
  duration: number;

  constructor(hash: string, duration: number) {
    this.hash = hash;
    this.duration = duration;
  }
}

class KugouCandidate {
  id: string;
  accesskey: string;

  constructor(id: string, accesskey: string) {
    this.id = id;
    this.accesskey = accesskey;
  }
}

function kugouTitleOk(songName: string | null, title: string): boolean {
  if (songName === null || songName.trim().length === 0 || title.trim().length === 0) {
    return true;
  }
  const left = songName.toLowerCase().replace(/\s+/g, ' ').trim();
  const right = title.toLowerCase().replace(/\s+/g, ' ').trim();
  return left.indexOf(right) >= 0 || right.indexOf(left) >= 0;
}

function firstKugouCandidate(raw: string | null): KugouCandidate | null {
  const root = asJsonRecord(safeJsonParse(raw));
  const candidates = root !== null ? asJsonArray(getRecordField(root, 'candidates')) : null;
  if (candidates === null || candidates.length === 0) {
    return null;
  }
  const first = asJsonRecord(candidates[0]);
  if (first === null) {
    return null;
  }
  const id = getStringField(first, 'id');
  const accesskey = getStringField(first, 'accesskey');
  if (id !== null && accesskey !== null) {
    return new KugouCandidate(id, accesskey);
  }
  return null;
}

export async function kugou(q: LyricsQuery): Promise<ParsedLyrics | null> {
  const albumPart = q.album !== null ? ` ${q.album}` : '';
  const keyword = `${stripParenthetical(q.title)} - ${stripParenthetical(q.artist)}${albumPart}`;
  const secs = Math.floor(q.durationMs / 1000);

  const searchSongUrl = urlWith('https://mobileservice.kugou.com/api/v3/search/song', new UrlQuery().set("version", 9108).set("plat", 0).set("pagesize", 8).set("showtype", 0).set("keyword", keyword));
  const songsRoot = asJsonRecord(safeJsonParse(await lyricsGet(searchSongUrl)));
  const dataObj = songsRoot !== null ? asJsonRecord(getRecordField(songsRoot, 'data')) : null;
  const infoArr = dataObj !== null ? asJsonArray(getRecordField(dataObj, 'info')) : null;

  const songItems: Array<KugouSongItem> = [];
  if (infoArr !== null) {
    for (let i = 0; i < infoArr.length; i++) {
      const item = asJsonRecord(infoArr[i]);
      if (item === null) {
        continue;
      }
      const hash = getStringField(item, 'hash');
      const dur = getNumberField(item, 'duration');
      const songName = getStringField(item, 'songname');
      if (hash !== null && hash.length > 0 && kugouTitleOk(songName, q.title)) {
        const dVal = dur !== null ? dur : -1;
        if (secs <= 0 || (dVal >= 0 && Math.abs(dVal - secs) <= 8)) {
          songItems.push(new KugouSongItem(hash, dur !== null ? dur : 0));
        }
      }
    }
  }
  songItems.sort((a: KugouSongItem, b: KugouSongItem): number => {
    return Math.abs(a.duration - secs) - Math.abs(b.duration - secs);
  });

  let candidate: KugouCandidate | null = null;
  for (let i = 0; i < songItems.length; i++) {
    const candUrl = urlWith('https://lyrics.kugou.com/search', new UrlQuery().set("ver", 1).set("man", 'yes').set("client", 'pc').set("hash", songItems[i].hash));
    candidate = firstKugouCandidate(await lyricsGet(candUrl));
    if (candidate !== null) {
      break;
    }
  }
  if (candidate === null) {
    return null;
  }

  const downloadUrl = urlWith('https://lyrics.kugou.com/download', new UrlQuery().set("fmt", 'lrc').set("charset", 'utf8').set("client", 'pc').set("ver", 1).set("id", candidate.id).set("accesskey", candidate.accesskey));
  const downloadRoot = asJsonRecord(safeJsonParse(await lyricsGet(downloadUrl)));
  const base64Content = downloadRoot !== null ? getStringField(downloadRoot, 'content') : null;
  if (base64Content === null || base64Content.length === 0) {
    return null;
  }
  try {
    const lrc = decodeUtf8(decodeBase64ToBytes(base64Content));
    const stripped = stripKugouCredits(lrc);
    if (isKugouInstrumentalNotice(stripped)) {
      return null;
    }
    return fromLines(parseLrc(stripped));
  } catch (_e) {
    return null;
  }
}

// ---- 8. LRCLIB (LrcLib.kt) ------------------------------------------------------------------

const LRCLIB_NOISE_REGEX: RegExp =
  /\((?:from|feat\.?|official|lyrical|video|audio|remix)[^)]*\)|\[[^\]]*\]|\b(?:official (?:video|audio|music video)|lyrical|full song|4k video)\b/gi;

function lrclibClean(s: string): string {
  const withoutNoise = s.replace(LRCLIB_NOISE_REGEX, ' ');
  const pipeParts = withoutNoise.split(' | ');
  const first = pipeParts[0].replace(/\s+/g, ' ').trim();
  return first.length > 0 ? first : s;
}

class LrcLibSearchHit {
  syncedLyrics: string;
  duration: number;

  constructor(syncedLyrics: string, duration: number) {
    this.syncedLyrics = syncedLyrics;
    this.duration = duration;
  }
}

export async function lrclib(q: LyricsQuery): Promise<ParsedLyrics | null> {
  const title = lrclibClean(q.title);
  const artist = lrclibClean(q.artist);
  const secs = Math.floor(q.durationMs / 1000);

  const getUrl = urlWith('https://lrclib.net/api/get', new UrlQuery().set("track_name", title).set("artist_name", artist).set("duration", secs));
  const exactRoot = asJsonRecord(safeJsonParse(await lyricsGet(getUrl)));
  let synced: string | null = exactRoot !== null ? getStringField(exactRoot, 'syncedLyrics') : null;

  if (synced === null || synced.trim().length === 0) {
    const searchUrl = urlWith('https://lrclib.net/api/search', new UrlQuery().set("track_name", title).set("artist_name", artist));
    const hitsArr = asJsonArray(safeJsonParse(await lyricsGet(searchUrl)));
    const validHits: Array<LrcLibSearchHit> = [];
    if (hitsArr !== null) {
      for (let i = 0; i < hitsArr.length; i++) {
        const h = asJsonRecord(hitsArr[i]);
        if (h !== null) {
          const sl = getStringField(h, 'syncedLyrics');
          const dur = getNumberField(h, 'duration');
          if (sl !== null && sl.trim().length > 0) {
            validHits.push(new LrcLibSearchHit(sl, dur !== null ? dur : 0));
          }
        }
      }
    }
    validHits.sort((a: LrcLibSearchHit, b: LrcLibSearchHit): number => {
      return Math.abs(a.duration - secs) - Math.abs(b.duration - secs);
    });
    synced = validHits.length > 0 ? validHits[0].syncedLyrics : null;
  }

  return (synced !== null && synced.trim().length > 0) ? fromLines(parseLrc(synced)) : null;
}

// ---- 9. Musixmatch (Musixmatch.kt) ----------------------------------------------------------

const MXM_BASE: string = 'https://apic.musixmatch.com/ws/1.1';
const MXM_APP_ID: string = 'mobile-app-v1.0';
const MXM_FALLBACK_SECRET: string = 'f09016176ba43a1cfd1031fbd6b3d26c';

function generateRandomGuid(): string {
  const hex = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      out += '-';
    } else if (i === 14) {
      out += '4';
    } else {
      const r = Math.floor(Math.random() * 16);
      out += hex.charAt(i === 19 ? ((r & 0x3) | 0x8) : r);
    }
  }
  return out;
}

const mxmGuid: string = generateRandomGuid();
let mxmSecret: string | null = null;
let mxmToken: string | null = null;

async function getMusixmatchSecret(): Promise<string> {
  if (mxmSecret !== null) {
    return mxmSecret;
  }
  try {
    const page = await lyricsGet('https://www.musixmatch.com/search');
    if (page !== null) {
      const scriptMatch = /src=["']([^"']*\/_next\/static\/chunks\/pages\/_app-[^"']+\.js)["']/i.exec(page);
      if (scriptMatch !== null && scriptMatch[1] !== undefined) {
        const scriptPath = scriptMatch[1];
        const scriptUrl = scriptPath.startsWith('http')
          ? scriptPath
          : `https://www.musixmatch.com${scriptPath.startsWith('/') ? '' : '/'}${scriptPath}`;
        const source = await lyricsGet(scriptUrl);
        if (source !== null) {
          const encodedMatch = /from\(\s*["']([^"']+)["']\s*\.split/.exec(source);
          if (encodedMatch !== null && encodedMatch[1] !== undefined) {
            const reversed = encodedMatch[1].split('').reverse().join('');
            const decoded = decodeUtf8(decodeBase64ToBytes(reversed)).trim();
            if (decoded.length > 0) {
              mxmSecret = decoded;
              return mxmSecret;
            }
          }
        }
      }
    }
  } catch (_e) {
    // Fallback
  }
  mxmSecret = MXM_FALLBACK_SECRET;
  return mxmSecret;
}

function padTwo(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

/** Ký URL Musixmatch với `<url><UTC yyyyMMdd>` bằng HMAC-SHA256. */
export function mxmSignUrl(url: string, secret: string): string {
  const normalizedUrl = url.replace(/%20/g, '+').replace(/ /g, '+');
  const now = new Date();
  const dateStr = `${now.getUTCFullYear()}${padTwo(now.getUTCMonth() + 1)}${padTwo(now.getUTCDate())}`;
  const hmacBytes = hmacSha256Bytes(secret, `${normalizedUrl}${dateStr}`);
  const signature = encodeBase64Bytes(hmacBytes);
  return `${normalizedUrl}&signature=${encodeURIComponent(signature)}&signature_protocol=sha256`;
}

async function mxmGet(buildUrl: (token: string) => string): Promise<JsonRecord | null> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const secret = await getMusixmatchSecret();
    if (mxmToken === null) {
      const tokenUrl = mxmSignUrl(
        urlWith(`${MXM_BASE}/token.get`, new UrlQuery().set("app_id", MXM_APP_ID).set("guid", mxmGuid).set("format", 'json')),
        secret
      );
      const tokenResp = asJsonRecord(safeJsonParse(await lyricsGet(tokenUrl)));
      const msg = tokenResp !== null ? asJsonRecord(getRecordField(tokenResp, 'message')) : null;
      const body = msg !== null ? asJsonRecord(getRecordField(msg, 'body')) : null;
      mxmToken = body !== null ? getStringField(body, 'user_token') : null;
      if (mxmToken === null) {
        return null;
      }
    }
    const signedReqUrl = mxmSignUrl(buildUrl(mxmToken), secret);
    const resp = asJsonRecord(safeJsonParse(await lyricsGet(signedReqUrl)));
    const message = resp !== null ? asJsonRecord(getRecordField(resp, 'message')) : null;
    const header = message !== null ? asJsonRecord(getRecordField(message, 'header')) : null;
    const status = header !== null ? getNumberField(header, 'status_code') : null;
    if (resp !== null && status !== 401 && status !== 402) {
      return message !== null ? asJsonRecord(getRecordField(message, 'body')) : null;
    }
    mxmToken = null;
    mxmSecret = null;
  }
  return null;
}

class MxmTrackCandidate {
  trackId: number;
  trackName: string;
  artistName: string;
  trackLength: number | null;
  hasSubtitles: boolean;
  hasRichsync: boolean;
  score: number;

  constructor(
    trackId: number,
    trackName: string,
    artistName: string,
    trackLength: number | null,
    hasSubtitles: boolean,
    hasRichsync: boolean,
    score: number
  ) {
    this.trackId = trackId;
    this.trackName = trackName;
    this.artistName = artistName;
    this.trackLength = trackLength;
    this.hasSubtitles = hasSubtitles;
    this.hasRichsync = hasRichsync;
    this.score = score;
  }
}

export async function musixmatch(q: LyricsQuery): Promise<ParsedLyrics | null> {
  const secs = Math.floor(q.durationMs / 1000);
  const searchBody = await mxmGet((token: string): string => {
    return urlWith(`${MXM_BASE}/track.search`, new UrlQuery().set("app_id", MXM_APP_ID).set("format", 'json').set("q_track", q.title).set("q_artist", q.artist).set("f_has_lyrics", 1).set("s_track_rating", 'desc').set("quorum_factor", 1).set("page_size", 10).set("page", 1).set("usertoken", token));
  });

  const trackListArr = searchBody !== null ? asJsonArray(getRecordField(searchBody, 'track_list')) : null;
  const candidates: Array<MxmTrackCandidate> = [];
  if (trackListArr !== null) {
    for (let i = 0; i < trackListArr.length; i++) {
      const wrapper = asJsonRecord(trackListArr[i]);
      const t = wrapper !== null ? asJsonRecord(getRecordField(wrapper, 'track')) : null;
      if (t === null) {
        continue;
      }
      const trackId = getNumberField(t, 'track_id');
      const trackName = getStringField(t, 'track_name');
      if (trackId === null || trackName === null) {
        continue;
      }
      const artistName = getStringField(t, 'artist_name');
      const trackLength = getNumberField(t, 'track_length');
      const hasSubtitles = (getNumberField(t, 'has_subtitles') !== null && (getNumberField(t, 'has_subtitles') as number) > 0);
      const hasRichsync = (getNumberField(t, 'has_richsync') !== null && (getNumberField(t, 'has_richsync') as number) > 0);

      const nameLower = trackName.trim().toLowerCase();
      const wantLower = q.title.trim().toLowerCase();
      let score = nameLower === wantLower ? 80 : ((nameLower.includes(wantLower) || wantLower.includes(nameLower)) ? 40 : 0);
      const aLower = (artistName !== null ? artistName : '').toLowerCase();
      if (aLower.includes(q.artist.toLowerCase())) {
        score += 40;
      }
      if (trackLength !== null) {
        const diff = Math.abs(trackLength - secs);
        score += diff <= 2 ? 30 : (diff <= 5 ? 15 : (diff <= 10 ? 5 : -20));
      }
      candidates.push(new MxmTrackCandidate(
        trackId,
        trackName,
        artistName !== null ? artistName : '',
        trackLength,
        hasSubtitles,
        hasRichsync,
        score
      ));
    }
  }

  candidates.sort((a: MxmTrackCandidate, b: MxmTrackCandidate): number => b.score - a.score);
  if (candidates.length === 0) {
    return null;
  }
  const best = candidates[0];

  if (best.hasRichsync) {
    const richBody = await mxmGet((token: string): string => {
      return urlWith(`${MXM_BASE}/track.richsync.get`, new UrlQuery().set("app_id", MXM_APP_ID).set("format", 'json').set("track_id", best.trackId).set("usertoken", token));
    });
    const richsyncObj = richBody !== null ? asJsonRecord(getRecordField(richBody, 'richsync')) : null;
    const richsyncText = richsyncObj !== null ? getStringField(richsyncObj, 'richsync_body') : null;
    const lines = richsyncText !== null ? parseRichSync(richsyncText) : [];
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].words.length > 0) {
        return new ParsedLyrics(lines, null);
      }
    }
  }

  if (!best.hasSubtitles) {
    return null;
  }
  const subBody = await mxmGet((token: string): string => {
    return urlWith(`${MXM_BASE}/track.subtitle.get`, new UrlQuery().set("app_id", MXM_APP_ID).set("format", 'json').set("track_id", best.trackId).set("subtitle_format", 'mxm').set("usertoken", token));
  });
  const subtitleObj = subBody !== null ? asJsonRecord(getRecordField(subBody, 'subtitle')) : null;
  const subtitleText = subtitleObj !== null ? getStringField(subtitleObj, 'subtitle_body') : null;
  const entries = subtitleText !== null ? asJsonArray(safeJsonParse(subtitleText)) : null;
  if (entries === null) {
    return null;
  }
  const subLines: Array<LyricLine> = [];
  for (let i = 0; i < entries.length; i++) {
    const e = asJsonRecord(entries[i]);
    if (e === null) {
      continue;
    }
    const text = getStringField(e, 'text');
    const timeObj = asJsonRecord(getRecordField(e, 'time'));
    const total = timeObj !== null ? getNumberField(timeObj, 'total') : null;
    if (text !== null && text.trim().length > 0 && total !== null) {
      subLines.push(line(Math.trunc(total * 1000), text.trim()));
    }
  }
  return fromLines(subLines);
}

// ---- 10. Genius (Genius.kt) -----------------------------------------------------------------

const GENIUS_NOISE_REGEX: RegExp =
  /\s*[([]\s*(?:from|feat\.?|ft\.?|featuring|with|prod\.?|produced by|official|lyrical|video|audio|remix|music video|visualizer|mv|hd|4k|hq|full song)[^)\]]*[)\]]|\s*\b(?:official\s+(?:music\s+)?(?:video|audio)|lyrical(?:\s+video)?|full\s+song|4k\s+video|hd\s+video|music\s+video)\b/gi;

function geniusClean(s: string): string {
  const step1 = s
    .replace(/[♪♫★☆【】《》「」~_]/g, ' ')
    .replace(GENIUS_NOISE_REGEX, ' ')
    .replace(/\b(?:prod(?:uced)?\.?(?:\s+by)?)\s+.*$/i, ' ');
  const pipeParts = step1.split(' | ');
  const cleaned = pipeParts[0].replace(/\s+/g, ' ').trim();
  return cleaned.length > 0 ? cleaned : s.trim();
}

class ScoredGeniusHit {
  url: string;
  score: number;

  constructor(url: string, score: number) {
    this.url = url;
    this.score = score;
  }
}

export async function genius(q: LyricsQuery): Promise<ParsedLyrics | null> {
  const title = geniusClean(q.title);
  const artist = geniusClean(q.artist);
  const bare = title
    .replace(/\s*[([].*?[)\]]/g, ' ')
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  const rawAttempts: Array<string> = [
    `${artist} ${title}`.trim(),
    `${artist} ${bare}`.trim(),
    bare.length > 0 ? bare : title,
  ];
  const attempts: Array<string> = [];
  for (let i = 0; i < rawAttempts.length; i++) {
    if (rawAttempts[i].length > 0 && !attempts.includes(rawAttempts[i])) {
      attempts.push(rawAttempts[i]);
    }
  }

  for (let aIdx = 0; aIdx < attempts.length; aIdx++) {
    const query = attempts[aIdx];
    const searchUrl = urlWith('https://genius.com/api/search/multi', new UrlQuery().set("q", query));
    const root = asJsonRecord(safeJsonParse(await lyricsGet(searchUrl)));
    const responseObj = root !== null ? asJsonRecord(getRecordField(root, 'response')) : null;
    const sections = responseObj !== null ? asJsonArray(getRecordField(responseObj, 'sections')) : null;
    if (sections === null) {
      continue;
    }

    const hits: Array<JsonRecord> = [];
    for (let i = 0; i < sections.length; i++) {
      const sec = asJsonRecord(sections[i]);
      if (sec !== null && getStringField(sec, 'type') === 'song') {
        const secHits = asJsonArray(getRecordField(sec, 'hits'));
        if (secHits !== null) {
          for (let j = 0; j < secHits.length; j++) {
            const hWrap = asJsonRecord(secHits[j]);
            const res = hWrap !== null ? asJsonRecord(getRecordField(hWrap, 'result')) : null;
            if (res !== null) {
              hits.push(res);
            }
          }
        }
      }
    }

    const t = (bare.length > 0 ? bare : title).toLowerCase();
    const a = artist.toLowerCase();
    const scored: Array<ScoredGeniusHit> = [];

    for (let i = 0; i < hits.length; i++) {
      const hit = hits[i];
      const hitUrl = getStringField(hit, 'url');
      if (hitUrl === null || hitUrl.length === 0) {
        continue;
      }
      const ht = (getStringField(hit, 'title') !== null ? (getStringField(hit, 'title') as string) : '').toLowerCase();
      const ha = (getStringField(hit, 'artist_names') !== null ? (getStringField(hit, 'artist_names') as string) : '').toLowerCase();
      const titleMatch = t.length > 0 && (ht === t || ht.includes(t) || t.includes(ht));
      const artistMatch = a.length > 0 && (ha === a || ha.includes(a) || a.includes(ha));
      if (!titleMatch && !artistMatch) {
        continue;
      }
      let score = (ht === t ? 50 : (titleMatch ? 25 : 0)) + (artistMatch ? (ha === a ? 40 : 20) : 0);
      const path = getStringField(hit, 'path') !== null ? (getStringField(hit, 'path') as string) : '';
      if (/translation/i.test(path) && !t.includes('translation')) {
        score -= 30;
      }
      if (/tracklist|album-art/i.test(path)) {
        score -= 50;
      }
      if (score > 0) {
        scored.push(new ScoredGeniusHit(hitUrl, score));
      }
    }

    scored.sort((x: ScoredGeniusHit, y: ScoredGeniusHit): number => y.score - x.score);
    if (scored.length === 0) {
      continue;
    }
    const html = await lyricsGet(scored[0].url);
    const lines = html !== null ? parseGeniusHtml(html) : [];
    if (lines.length > 0) {
      return new ParsedLyrics(lines, null);
    }
  }
  return null;
}

// ---- 11. YouTube Music & YouTube Captions (YouTubeLyrics.kt) --------------------------------

export function collectObjectsNamed(
  node: Object | null | undefined,
  name: string,
  out: Array<JsonRecord>
): Array<JsonRecord> {
  const arr = asJsonArray(node);
  if (arr !== null) {
    for (let i = 0; i < arr.length; i++) {
      collectObjectsNamed(arr[i], name, out);
    }
    return out;
  }
  const obj = asJsonRecord(node);
  if (obj !== null) {
    const keys = Object.keys(obj);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const val = obj[k];
      if (k === name) {
        const childRec = asJsonRecord(val);
        if (childRec !== null) {
          out.push(childRec);
        }
      }
      collectObjectsNamed(val, name, out);
    }
  }
  return out;
}

export function extractYoutubeText(node: Object | null | undefined): string {
  if (typeof node === 'string') {
    return node;
  }
  const arr = asJsonArray(node);
  if (arr !== null) {
    const parts: Array<string> = [];
    for (let i = 0; i < arr.length; i++) {
      parts.push(extractYoutubeText(arr[i]));
    }
    return parts.join('');
  }
  const o = asJsonRecord(node);
  if (o !== null) {
    const textField = getStringField(o, 'text');
    if (textField !== null) {
      return textField;
    }
    const simpleText = getStringField(o, 'simpleText');
    if (simpleText !== null) {
      return simpleText;
    }
    const keys = Object.keys(o);
    const parts: Array<string> = [];
    for (let i = 0; i < keys.length; i++) {
      parts.push(extractYoutubeText(o[keys[i]]));
    }
    return parts.join('');
  }
  return '';
}

/** Callback tùy chọn để kết nối với InnertubeClient khi lấy YouTube Lyrics / Captions. */
export interface YouTubeLyricsProviderBridge {
  fetchPlainLyrics: (videoId: string) => Promise<string | null>;
  fetchTranscriptJson: (videoId: string) => Promise<Object | null>;
}

let youtubeBridge: YouTubeLyricsProviderBridge | null = null;

export function registerYouTubeLyricsBridge(bridge: YouTubeLyricsProviderBridge): void {
  youtubeBridge = bridge;
}

export async function youtubeMusicLyrics(q: LyricsQuery): Promise<ParsedLyrics | null> {
  if (!/^[A-Za-z0-9_-]{11}$/.test(q.videoId) || youtubeBridge === null) {
    return null;
  }
  try {
    const text = await youtubeBridge.fetchPlainLyrics(q.videoId);
    if (text === null || text.trim().length === 0) {
      return null;
    }
    const rawLines = text.split(/\r?\n/);
    const lines: Array<LyricLine> = [];
    for (let i = 0; i < rawLines.length; i++) {
      const t = rawLines[i].trim();
      if (t.length > 0) {
        lines.push(line(0, t));
      }
    }
    return fromLines(lines);
  } catch (_e) {
    return null;
  }
}

export async function youtubeCaptions(q: LyricsQuery): Promise<ParsedLyrics | null> {
  if (!/^[A-Za-z0-9_-]{11}$/.test(q.videoId) || youtubeBridge === null) {
    return null;
  }
  try {
    const responseData = await youtubeBridge.fetchTranscriptJson(q.videoId);
    if (responseData === null) {
      return null;
    }
    const cues = collectObjectsNamed(responseData, 'transcriptCueRenderer', []);
    const lines: Array<LyricLine> = [];
    for (let i = 0; i < cues.length; i++) {
      const cue = cues[i];
      const startStr = getStringField(cue, 'startOffsetMs');
      const startNum = startStr !== null ? Number(startStr) : getNumberField(cue, 'startOffsetMs');
      const text = extractYoutubeText(getRecordField(cue, 'cue')).replace(/^[\s♪]+|[\s♪]+$/g, '');
      if (startNum !== null && Number.isFinite(startNum) && text.length > 0) {
        lines.push(line(startNum, text));
      }
    }
    lines.sort((a: LyricLine, b: LyricLine): number => a.timeMs - b.timeMs);
    let latest = 0;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].timeMs > latest) {
        latest = lines[i].timeMs;
      }
    }
    if (q.durationMs > 30000 && latest > 0 && latest < q.durationMs / 20) {
      for (let i = 0; i < lines.length; i++) {
        lines[i].timeMs = lines[i].timeMs * 1000;
      }
    }
    return fromLines(lines);
  } catch (_e) {
    return null;
  }
}

// ---- LyricsRepository.kt & repository.ts (Quản lý điều phối, cache và đua ưu tiên) ----------

export class LyricsTrack {
  videoId: string;
  title: string;
  artist: string;
  durationMs: number;
  album: string | null;

  constructor(
    videoId: string,
    title: string,
    artist: string,
    durationMs: number,
    album: string | null = null
  ) {
    this.videoId = videoId;
    this.title = title;
    this.artist = artist;
    this.durationMs = durationMs;
    this.album = album;
  }
}

export class LyricsResult {
  source: LyricsSourceId;
  label: string;
  lines: Array<LyricLine>;
  ttml: string;
  wordSynced: boolean;
  synced: boolean;

  constructor(
    source: LyricsSourceId,
    label: string,
    lines: Array<LyricLine>,
    ttml: string,
    wordSynced: boolean,
    synced: boolean
  ) {
    this.source = source;
    this.label = label;
    this.lines = lines;
    this.ttml = ttml;
    this.wordSynced = wordSynced;
    this.synced = synced;
  }
}

export type SourceState = 'pending' | 'found' | 'missing';

export interface LyricsLookupOptions {
  only?: LyricsSourceId;
  enabledSources?: Array<LyricsSourceId>;
  paxsenixKey?: string;
  preferSyllables?: boolean;
  onSource?: (source: LyricsSourceId, state: SourceState) => void;
}

class CachedLyricsEntry {
  at: number;
  result: LyricsResult | null;

  constructor(at: number, result: LyricsResult | null) {
    this.at = at;
    this.result = result;
  }
}

class RacingJobEntry {
  source: LyricsSourceId;
  job: Promise<LyricsResult | null> | null;

  constructor(source: LyricsSourceId, job: Promise<LyricsResult | null> | null) {
    this.source = source;
    this.job = job;
  }
}

const IDENTIFY_TIMEOUT_MS: number = 2500;
const CACHE_TTL_MS: number = 12 * 60 * 60000;

const isrcsCache: Map<string, string> = new Map<string, string>();
const lyricsCache: Map<string, CachedLyricsEntry> = new Map<string, CachedLyricsEntry>();

function rememberIsrc(videoId: string, isrc: string | null | undefined): void {
  if (isrc === null || isrc === undefined || isrc.length === 0 || videoId.length === 0) {
    return;
  }
  isrcsCache.delete(videoId);
  isrcsCache.set(videoId, isrc);
  if (isrcsCache.size > 100) {
    const firstKey = isrcsCache.keys().next().value as string | undefined;
    if (firstKey !== undefined) {
      isrcsCache.delete(firstKey);
    }
  }
}

export function forgetLyrics(): void {
  lyricsCache.clear();
}

function buildLyricsResult(source: LyricsSourceId, parsed: ParsedLyrics): LyricsResult {
  const lines = withBackgroundVocals(parsed.lines);
  const info = sourceById(source);
  const label = info !== undefined ? info.label : source;
  const ttml = parsed.ttml !== null ? parsed.ttml : writeTtml(lines);
  let wordSynced = false;
  let synced = false;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].words.length > 0) {
      wordSynced = true;
      synced = true;
      break;
    }
    if (lines[i].timeMs > 0) {
      synced = true;
    }
  }
  return new LyricsResult(source, label, lines, ttml, wordSynced, synced);
}

function withPromiseTimeout<T>(promise: Promise<T | null>, ms: number): Promise<T | null> {
  return new Promise<T | null>((resolve) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        resolve(null);
      }
    }, ms);
    promise.then((val: T | null) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        resolve(val);
      }
    }).catch(() => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        resolve(null);
      }
    });
  });
}

function defaultEnabledSources(): Array<LyricsSourceId> {
  const list: Array<LyricsSourceId> = [];
  for (let i = 0; i < LYRICS_SOURCES.length; i++) {
    const id = LYRICS_SOURCES[i].id;
    if (id !== 'paxsenix-spotify' && id !== 'paxsenix-musixmatch') {
      list.push(id);
    }
  }
  return list;
}

/**
 * Tra cứu lời bài hát từ tất cả các nguồn đang bật theo đúng thứ tự ưu tiên của BitChord:
 * - Gọi đồng thời các nguồn nhưng xét kết quả theo thứ tự ưu tiên.
 * - Nguồn có word-synced (syllable/word timing) thắng ngay lập tức.
 * - Nếu bật `preferSyllables`, giữ lại kết quả line-synced đầu tiên làm dự phòng và tiếp tục tìm word-synced.
 * - Genius chỉ được gọi khi tất cả các nguồn phía trên đều không có kết quả.
 */
export async function lookupLyrics(
  track: LyricsTrack,
  options?: LyricsLookupOptions
): Promise<LyricsResult | null> {
  const only: LyricsSourceId | undefined = options !== undefined ? options.only : undefined;
  const sequence: Array<LyricsSourceId> = only !== undefined
    ? [only]
    : (options !== undefined && options.enabledSources !== undefined
        ? options.enabledSources
        : defaultEnabledSources());
  if (sequence.length === 0) {
    return null;
  }

  const paxsenixKey: string = (options !== undefined && options.paxsenixKey !== undefined) ? options.paxsenixKey : '';
  const preferSyllables: boolean = (options !== undefined && options.preferSyllables !== undefined) ? options.preferSyllables : true;
  const onSource = options !== undefined ? options.onSource : undefined;

  const cacheKey = `v3|${track.videoId}|${track.durationMs}|${track.title}|${track.artist}|${only !== undefined ? only : ''}|${sequence.join(',')}|${preferSyllables}`;
  const cached = lyricsCache.get(cacheKey);
  if (cached !== undefined && Date.now() - cached.at < CACHE_TTL_MS) {
    return cached.result;
  }

  const existingIsrc = isrcsCache.get(track.videoId);
  const query = new LyricsQuery(
    track.videoId,
    forLyricsSearch(track.title),
    artistForLyricsSearch(track.artist),
    track.durationMs,
    track.album,
    existingIsrc !== undefined ? existingIsrc : null
  );

  let biniHit: BiniHit | null = null;
  if (query.isrc === null && sequence.includes('bini')) {
    biniHit = await withPromiseTimeout(biniIdentify(query), IDENTIFY_TIMEOUT_MS);
    if (biniHit !== null && biniHit.isrc !== null) {
      rememberIsrc(track.videoId, biniHit.isrc);
      query.isrc = biniHit.isrc;
    }
  }

  const sharedDocuments: Map<string, Promise<string | null>> = new Map<string, Promise<string | null>>();
  const sharedGet: SharedGetFn = (url: string): Promise<string | null> => {
    const existing = sharedDocuments.get(url);
    if (existing !== undefined) {
      return existing;
    }
    const pending = lyricsGet(url);
    sharedDocuments.set(url, pending);
    return pending;
  };

  const fetchFromSource = async (source: LyricsSourceId): Promise<ParsedLyrics | null> => {
    switch (source) {
      case 'lrc-red':
        return lrcRed(query, sharedGet);
      case 'bini': {
        const res = await bini(query, sharedGet, biniHit);
        if (res !== null) {
          rememberIsrc(track.videoId, res.isrc);
          return res.parsed;
        }
        return null;
      }
      case 'better-lyrics':
        return betterLyrics(query);
      case 'better-lyrics-portato':
        return betterLyricsPortato(query);
      case 'paxsenix':
        return paxSenix(query);
      case 'paxsenix-spotify':
        return paxSenixSpotify(query, paxsenixKey);
      case 'paxsenix-musixmatch':
        return paxSenixMusixmatch(query, paxsenixKey);
      case 'lyrics-plus':
        return lyricsPlus(query);
      case 'unison':
        return unison(query);
      case 'youtube-captions':
        return youtubeCaptions(query);
      case 'youtube-music':
        return youtubeMusicLyrics(query);
      case 'kugou':
        return kugou(query);
      case 'lrclib':
        return lrclib(query);
      case 'musixmatch':
        return musixmatch(query);
      case 'genius':
        return genius(query);
    }
  };

  const runSource = async (source: LyricsSourceId): Promise<LyricsResult | null> => {
    if (onSource !== undefined) {
      onSource(source, 'pending');
    }
    try {
      const parsed = await fetchFromSource(source);
      let hasText = false;
      if (parsed !== null) {
        for (let i = 0; i < parsed.lines.length; i++) {
          if (parsed.lines[i].text.trim().length > 0) {
            hasText = true;
            break;
          }
        }
      }
      const result: LyricsResult | null = (parsed !== null && hasText)
        ? buildLyricsResult(source, parsed)
        : null;
      if (onSource !== undefined) {
        onSource(source, result !== null ? 'found' : 'missing');
      }
      return result;
    } catch (_e) {
      if (onSource !== undefined) {
        onSource(source, 'missing');
      }
      return null;
    }
  };

  const racing: Array<RacingJobEntry> = [];
  for (let i = 0; i < sequence.length; i++) {
    const src = sequence[i];
    racing.push(new RacingJobEntry(src, src === 'genius' ? null : runSource(src)));
  }

  let lineSynced: LyricsResult | null = null;
  let plain: LyricsResult | null = null;
  let winner: LyricsResult | null = null;
  let exact: LyricsResult | null = null;

  for (let i = 0; i < racing.length; i++) {
    const entry = racing[i];
    if (entry.source === 'genius' && (lineSynced !== null || plain !== null || exact !== null)) {
      continue;
    }
    const found = await (entry.job !== null ? entry.job : runSource(entry.source));
    if (found === null) {
      continue;
    }
    if (entry.source === 'youtube-captions' && found.synced) {
      exact = found;
      continue;
    }
    if (entry.source === 'youtube-music') {
      if (plain === null) {
        plain = found;
      }
      continue;
    }
    if (found.wordSynced) {
      if (winner === null) {
        winner = found;
      }
      continue;
    }
    if (found.synced && !preferSyllables) {
      if (winner === null) {
        winner = found;
      }
      continue;
    }
    if (found.synced) {
      if (lineSynced === null) {
        lineSynced = found;
      }
    } else {
      if (plain === null) {
        plain = found;
      }
    }
  }

  const spansSong = (result: LyricsResult): boolean => {
    if (track.durationMs < 30000 || result.lines.length === 0) {
      return true;
    }
    let last = 0;
    for (let n = 0; n < result.lines.length; n++) {
      if (result.lines[n].timeMs > last) {
        last = result.lines[n].timeMs;
      }
    }
    return last > track.durationMs * 0.45 && last < track.durationMs * 1.35;
  };
  if (winner !== null && !spansSong(winner)) {
    winner = null;
  }
  if (winner === null && lineSynced !== null && spansSong(lineSynced)) {
    winner = lineSynced;
  }
  if (winner === null && exact !== null) {
    winner = exact;
  }
  if (winner === null) {
    winner = plain;
  }
  lyricsCache.set(cacheKey, new CachedLyricsEntry(Date.now(), winner));
  return winner;
}