/**
 * InnertubeApi.ets
 * Chuyển đổi từ:
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/innertube/Innertube.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/innertube/InnertubeParser.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/innertube/PlayerClient.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/LocaleTags.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/auth/DataSyncId.kt
 * - shared/src/commonMain/kotlin/com/music/bitchord/data/model/Models.kt
 * - shared/src/commonMain/kotlin/com/music/bitchord/data/model/VersionTimeMap.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/model/ArtistCredits.kt
 * - web/app/src/data/music/types.ts, api.ts, mappers.ts
 *
 * Chuẩn cú pháp: HarmonyOS NEXT ArkTS (Strict Mode - sử dụng `@kit.NetworkKit`,
 * không dùng any/unknown, không object spread, không destructuring, không dùng `in`).
 */

import { http } from '@kit.NetworkKit';
import {
  asJsonArray,
  asJsonRecord,
  getBooleanField,
  getNumberField,
  getRecordField,
  getStringField,
  isJsonRecord,
  JsonRecord,
  safeJsonParse,
} from './lyricsparser';
import {
  encodeBase64Bytes,
  encodeUtf8,
  registerYouTubeLyricsBridge,
  urlWith,
  UrlQuery,
  YouTubeLyricsProviderBridge,
} from './lyricsproviders';

// ============================================================================
// 1. SHA-1 Thuần ArkTS (Dùng để tạo chữ ký xác thực SAPISIDHASH của Google)
// ============================================================================

function rotl32(x: number, n: number): number {
  return ((x << n) | (x >>> (32 - n))) >>> 0;
}

/** Tính mã băm SHA-1 trả về chuỗi hex chữ thường (40 ký tự) cho SAPISIDHASH. */
export function sha1Hex(input: string): string {
  const bytes = encodeUtf8(input);
  const bitLen = bytes.length * 8;
  const padLen = ((bytes.length + 9 + 63) & ~63);
  const padded = new Uint8Array(padLen);
  padded.set(bytes, 0);
  padded[bytes.length] = 0x80;

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

  let h0 = 0x67452301;
  let h1 = 0xefcdab89;
  let h2 = 0x98badcfe;
  let h3 = 0x10325476;
  let h4 = 0xc3d2e1f0;

  const w = new Array<number>(80).fill(0);
  for (let offset = 0; offset < padLen; offset += 64) {
    for (let i = 0; i < 16; i++) {
      const idx = offset + i * 4;
      w[i] = ((padded[idx] << 24) | (padded[idx + 1] << 16) | (padded[idx + 2] << 8) | padded[idx + 3]) >>> 0;
    }
    for (let i = 16; i < 80; i++) {
      w[i] = rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;

    for (let i = 0; i < 80; i++) {
      let f = 0;
      let k = 0;
      if (i < 20) {
        f = ((b & c) | ((~b) & d)) >>> 0;
        k = 0x5a827999;
      } else if (i < 40) {
        f = (b ^ c ^ d) >>> 0;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = ((b & c) | (b & d) | (c & d)) >>> 0;
        k = 0x8f1bbcdc;
      } else {
        f = (b ^ c ^ d) >>> 0;
        k = 0xca62c1d6;
      }
      const temp = (rotl32(a, 5) + f + e + k + w[i]) >>> 0;
      e = d;
      d = c;
      c = rotl32(b, 30);
      b = a;
      a = temp;
    }

    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
  }

  const words = [h0, h1, h2, h3, h4];
  let hex = '';
  for (let i = 0; i < words.length; i++) {
    const s = (words[i] >>> 0).toString(16);
    hex += s.length < 8 ? '0'.repeat(8 - s.length) + s : s;
  }
  return hex;
}

// ============================================================================
// 2. DataSyncId.kt & LocaleTags.kt
// ============================================================================

/** Chuẩn hóa `DATASYNC_ID` ("account||delegated" -> lấy phần active). */
export function normalizeDataSyncId(raw: string | null | undefined): string | null {
  if (raw === null || raw === undefined) {
    return null;
  }
  const value = raw.trim();
  if (value.length === 0) {
    return null;
  }
  const sepIdx = value.indexOf('||');
  if (sepIdx < 0) {
    return value;
  }
  const second = value.slice(sepIdx + 2).trim();
  if (second.length > 0) {
    return second;
  }
  const first = value.slice(0, sepIdx).trim();
  return first.length > 0 ? first : null;
}

export class LocaleTags {
  static readonly ZH_HANT: string = 'zh-Hant';
  static readonly ZH_HANS: string = 'zh-Hans';
  static readonly ZH_TW_WIRE: string = 'zh-TW';
  static readonly ZH_CN_WIRE: string = 'zh-CN';

  static normalizeAppTag(raw: string | null | undefined): string {
    if (raw === null || raw === undefined) {
      return 'en';
    }
    const tag = raw.trim().replace(/_/g, '-');
    if (tag.length === 0) {
      return 'en';
    }
    const lower = tag.toLowerCase();
    if (lower.startsWith('zh')) {
      if (lower.includes('hant')) {
        return LocaleTags.ZH_HANT;
      }
      if (lower.includes('hans')) {
        return LocaleTags.ZH_HANS;
      }
      if (lower.includes('tw') || lower.includes('hk') || lower.includes('mo')) {
        return LocaleTags.ZH_HANT;
      }
      if (lower.includes('cn') || lower.includes('sg') || lower.includes('my')) {
        return LocaleTags.ZH_HANS;
      }
      return LocaleTags.ZH_HANS;
    }
    const dashIdx = lower.indexOf('-');
    const base = dashIdx >= 0 ? lower.slice(0, dashIdx) : lower;
    if (base === 'iw') {
      return 'he';
    }
    if (base === 'in') {
      return 'id';
    }
    if (base === 'ji') {
      return 'yi';
    }
    return base.length > 0 ? base : 'en';
  }

  static ytHl(appTag: string): string {
    const norm = LocaleTags.normalizeAppTag(appTag);
    if (norm === LocaleTags.ZH_HANT) {
      return LocaleTags.ZH_TW_WIRE;
    }
    if (norm === LocaleTags.ZH_HANS) {
      return LocaleTags.ZH_CN_WIRE;
    }
    const dashIdx = norm.indexOf('-');
    return dashIdx >= 0 ? norm.slice(0, dashIdx) : norm;
  }

  static ytGl(appTag: string): string {
    const norm = LocaleTags.normalizeAppTag(appTag);
    if (norm === LocaleTags.ZH_HANT) {
      return 'TW';
    }
    if (norm === LocaleTags.ZH_HANS) {
      return 'HK';
    }
    if (norm === 'vi') {
      return 'VN';
    }
    if (norm === 'ja') {
      return 'JP';
    }
    return 'US';
  }

  static ytSearchGl(appTag: string): string | null {
    return LocaleTags.ytGl(appTag);
  }

  static acceptLanguage(appTag: string): string {
    const norm = LocaleTags.normalizeAppTag(appTag);
    if (norm === LocaleTags.ZH_HANT) {
      return 'zh-TW,zh-Hant;q=0.9,zh;q=0.8,en-US;q=0.7,en;q=0.6';
    }
    if (norm === LocaleTags.ZH_HANS) {
      return 'zh-CN,zh-Hans;q=0.9,zh;q=0.8,en-US;q=0.7,en;q=0.6';
    }
    if (norm === 'en') {
      return 'en-US,en;q=0.9';
    }
    const dashIdx = norm.indexOf('-');
    const base = dashIdx >= 0 ? norm.slice(0, dashIdx) : norm;
    return `${base},en-US;q=0.8,en;q=0.7`;
  }

  static translationWireTarget(tag: string): string {
    const t = tag.trim().replace(/_/g, '-');
    const lower = t.toLowerCase();
    if (lower === 'zh-tw' || lower === 'zh-hant') {
      return LocaleTags.ZH_TW_WIRE;
    }
    if (lower === 'zh-cn' || lower === 'zh-hans') {
      return LocaleTags.ZH_CN_WIRE;
    }
    const norm = LocaleTags.normalizeAppTag(t);
    if (norm === LocaleTags.ZH_HANT) {
      return LocaleTags.ZH_TW_WIRE;
    }
    if (norm === LocaleTags.ZH_HANS) {
      return LocaleTags.ZH_CN_WIRE;
    }
    return t.length > 0 ? t : 'en';
  }

  static sameLanguageScriptAware(first: string, second: string): boolean {
    const canon = (tag: string): string => {
      const lower = tag.trim().replace(/_/g, '-').toLowerCase();
      if (lower.startsWith('zh')) {
        if (lower.includes('tw') || lower.includes('hant') || lower.includes('hk') || lower.includes('mo')) {
          return 'zh-hant';
        }
        if (lower.includes('cn') || lower.includes('hans') || lower.includes('sg') || lower.includes('my')) {
          return 'zh-hans';
        }
        return 'zh';
      }
      const dashIdx = lower.indexOf('-');
      return dashIdx >= 0 ? lower.slice(0, dashIdx) : lower;
    };
    return canon(first) === canon(second);
  }

  static isChineseTag(tag: string): boolean {
    return tag.trim().replace(/_/g, '-').toLowerCase().startsWith('zh');
  }
}

// ============================================================================
// 3. PlayerClient.kt (Nhận diện định danh Client của stream googlevideo)
// ============================================================================

function extractUrlQueryParam(url: string, param: string): string | null {
  const qIdx = url.indexOf('?');
  if (qIdx < 0) {
    return null;
  }
  const hashIdx = url.indexOf('#', qIdx);
  const query = hashIdx >= 0 ? url.slice(qIdx + 1, hashIdx) : url.slice(qIdx + 1);
  const pairs = query.split('&');
  for (let i = 0; i < pairs.length; i++) {
    const eqIdx = pairs[i].indexOf('=');
    const k = eqIdx >= 0 ? pairs[i].slice(0, eqIdx) : pairs[i];
    if (decodeURIComponent(k) === param) {
      const v = eqIdx >= 0 ? pairs[i].slice(eqIdx + 1) : '';
      return decodeURIComponent(v);
    }
  }
  return null;
}

function extractUrlHost(url: string): string {
  const afterScheme = url.includes('://') ? url.slice(url.indexOf('://') + 3) : (url.startsWith('//') ? url.slice(2) : url);
  const slashIdx = afterScheme.indexOf('/');
  const hostPort = slashIdx >= 0 ? afterScheme.slice(0, slashIdx) : afterScheme;
  const colonIdx = hostPort.indexOf(':');
  const qIdx = hostPort.indexOf('?');
  let end = hostPort.length;
  if (colonIdx >= 0 && colonIdx < end) {
    end = colonIdx;
  }
  if (qIdx >= 0 && qIdx < end) {
    end = qIdx;
  }
  return hostPort.slice(0, end).toLowerCase();
}

export class PlayerClient {
  clientName: string;
  clientVersion: string;
  userAgent: string;
  origin: string | null;

  constructor(
    clientName: string,
    clientVersion: string,
    userAgent: string,
    origin: string | null = null
  ) {
    this.clientName = clientName;
    this.clientVersion = clientVersion;
    this.userAgent = userAgent;
    this.origin = origin;
  }

  get referer(): string | null {
    return this.origin !== null ? `${this.origin}/` : null;
  }

  mediaHeaders(): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': this.userAgent,
    };
    if (this.origin !== null) {
      headers['Origin'] = this.origin;
    }
    if (this.referer !== null) {
      headers['Referer'] = this.referer as string;
    }
    return headers;
  }

  static readonly MUSIC_ORIGIN: string = 'https://music.youtube.com';
  static readonly YOUTUBE_ORIGIN: string = 'https://www.youtube.com';
  static readonly WEB_USER_AGENT: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

  static readonly IOS: PlayerClient = new PlayerClient(
    'IOS',
    '21.26.4',
    'com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)'
  );

  static readonly IOS_RECENT: PlayerClient = new PlayerClient(
    'IOS',
    '21.29.1',
    'com.google.ios.youtube/21.29.1 (iPhone16,2; U; CPU iOS 18_5 like Mac OS X;)'
  );

  static readonly ANDROID: PlayerClient = new PlayerClient(
    'ANDROID',
    '21.26.364',
    'com.google.android.youtube/21.26.364 (Linux; U; Android 15; en_US; Pixel 9 Pro; Build/AP4A.250205.002; Cronet/132.0.6834.79) gzip'
  );

  static readonly ANDROID_MUSIC: PlayerClient = new PlayerClient(
    'ANDROID_MUSIC',
    '8.39.42',
    'com.google.android.apps.youtube.music/8.39.42 (Linux; U; Android 15; en_US; Pixel 9 Pro; Build/AP4A.250205.002) gzip'
  );

  static readonly ANDROID_VR: PlayerClient = new PlayerClient(
    'ANDROID_VR',
    '1.65.10',
    'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip'
  );

  static readonly ANDROID_VR_LEGACY: PlayerClient = new PlayerClient(
    'ANDROID_VR',
    '1.43.32',
    'com.google.android.apps.youtube.vr.oculus/1.43.32 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)'
  );

  static readonly WEB_REMIX: PlayerClient = new PlayerClient(
    'WEB_REMIX',
    '1.20260707.12.00',
    PlayerClient.WEB_USER_AGENT,
    PlayerClient.MUSIC_ORIGIN
  );

  static readonly WEB: PlayerClient = new PlayerClient(
    'WEB',
    '2.20260708.00.00',
    PlayerClient.WEB_USER_AGENT,
    PlayerClient.YOUTUBE_ORIGIN
  );

  static readonly TVHTML5: PlayerClient = new PlayerClient(
    'TVHTML5',
    '7.20260707.07.00',
    'Mozilla/5.0(SMART-TV; Linux; Tizen 4.0.0.2) AppleWebkit/605.1.15 (KHTML, like Gecko) SamsungBrowser/9.2 TV Safari/605.1.15',
    PlayerClient.YOUTUBE_ORIGIN
  );

  private static readonly RANGE_BYTES: number = 1024 * 1024;
  private static readonly NARROW_RANGE_BYTES: number = 512 * 1024;

  static forStreamUrl(url: string): PlayerClient {
    const rawName = extractUrlQueryParam(url, 'c');
    if (rawName === null) {
      return PlayerClient.IOS;
    }
    const name = rawName.toUpperCase();
    const version = extractUrlQueryParam(url, 'cver');
    if (name.startsWith('IOS')) {
      return version === PlayerClient.IOS_RECENT.clientVersion ? PlayerClient.IOS_RECENT : PlayerClient.IOS;
    }
    if (name === 'ANDROID_VR') {
      return version === PlayerClient.ANDROID_VR_LEGACY.clientVersion ? PlayerClient.ANDROID_VR_LEGACY : PlayerClient.ANDROID_VR;
    }
    if (name === 'ANDROID_MUSIC') {
      return PlayerClient.ANDROID_MUSIC;
    }
    if (name.startsWith('ANDROID')) {
      return PlayerClient.ANDROID;
    }
    if (name.startsWith('TVHTML5')) {
      return PlayerClient.TVHTML5;
    }
    if (name === 'WEB_REMIX') {
      return PlayerClient.WEB_REMIX;
    }
    if (name.startsWith('WEB') || name === 'MWEB') {
      return PlayerClient.WEB;
    }
    if (name === 'VISIONOS') {
      const v = version !== null ? version : '1.02';
      return new PlayerClient(
        'VISIONOS',
        v,
        `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15`
      );
    }
    return PlayerClient.IOS;
  }

  static rangeBytesFor(url: string): number {
    const host = extractUrlHost(url);
    if (!host.endsWith('googlevideo.com')) {
      return Number.MAX_SAFE_INTEGER;
    }
    const rawName = extractUrlQueryParam(url, 'c');
    const name = rawName !== null ? rawName.toUpperCase() : '';
    if (name === 'ANDROID_VR' || name.startsWith('TVHTML5_SIMPLY')) {
      return PlayerClient.NARROW_RANGE_BYTES;
    }
    return PlayerClient.RANGE_BYTES;
  }
}

// ============================================================================
// 4. Models.kt, VersionTimeMap.kt & ArtistCredits.kt
// ============================================================================

export enum QueueTier {
  USER_QUEUE = 'USER_QUEUE',
  CONTEXT = 'CONTEXT',
  AUTOPLAY = 'AUTOPLAY',
}

export enum BrowseType {
  ALBUM = 'ALBUM',
  ARTIST = 'ARTIST',
  PLAYLIST = 'PLAYLIST',
  OTHER = 'OTHER',
}

export enum PlaybackSourceType {
  HOME = 'HOME',
  SEARCH = 'SEARCH',
  HISTORY = 'HISTORY',
  REPLAY = 'REPLAY',
  EXPLORE = 'EXPLORE',
  BROWSE = 'BROWSE',
  SHARED_LINK = 'SHARED_LINK',
  QUEUE = 'QUEUE',
}

export enum ShelfLayout {
  CARDS = 'CARDS',
  LIST = 'LIST',
  VIDEO = 'VIDEO',
}

export enum LikeStatus {
  LIKE = 'LIKE',
  DISLIKE = 'DISLIKE',
  INDIFFERENT = 'INDIFFERENT',
}

export enum PlaylistPrivacy {
  PRIVATE = 'PRIVATE',
  UNLISTED = 'UNLISTED',
  PUBLIC = 'PUBLIC',
}

export class SearchFilterInfo {
  key: string;
  label: string;
  params: string | null;

  constructor(key: string, label: string, params: string | null) {
    this.key = key;
    this.label = label;
    this.params = params;
  }
}

function buildSearchFilters(): Record<string, SearchFilterInfo> {
  const filters: Record<string, SearchFilterInfo> = {};
  filters['ALL'] = new SearchFilterInfo('ALL', 'All', null);
  filters['SONGS'] = new SearchFilterInfo('SONGS', 'Songs', 'EgWKAQIIAWoKEAkQChAFEAMQBA==');
  filters['VIDEOS'] = new SearchFilterInfo('VIDEOS', 'Videos', 'EgWKAQIQAWoKEAkQChAFEAMQBA==');
  filters['ALBUMS'] = new SearchFilterInfo('ALBUMS', 'Albums', 'EgWKAQIYAWoKEAkQChAFEAMQBA==');
  filters['ARTISTS'] = new SearchFilterInfo('ARTISTS', 'Artists', 'EgWKAQIgAWoKEAkQChAFEAMQBA==');
  filters['PLAYLISTS'] = new SearchFilterInfo('PLAYLISTS', 'Playlists', 'EgWKAQIoAWoKEAkQChAFEAMQBA==');
  return filters;
}

export const SEARCH_FILTERS: Record<string, SearchFilterInfo> = buildSearchFilters();

export class ArtistRef {
  name: string;
  browseId: string | null;

  constructor(name: string, browseId: string | null = null) {
    this.name = name;
    this.browseId = browseId;
  }
}

export class AlbumRef {
  name: string;
  browseId: string | null;

  constructor(name: string, browseId: string | null = null) {
    this.name = name;
    this.browseId = browseId;
  }
}

export interface SongOptions {
  durationText?: string | null;
  artistId?: string | null;
  artists?: Array<ArtistRef>;
  albumId?: string | null;
  albumName?: string | null;
  isVideo?: boolean;
  isVideoOrigin?: boolean;
  setVideoId?: string | null;
  queueTier?: QueueTier;
  queueEntryId?: string | null;
  radioName?: string | null;
  localUri?: string | null;
  downloadFormat?: string | null;
  localPath?: string | null;
  localDateAddedSeconds?: number | null;
  localDateModifiedSeconds?: number | null;
  trackNumber?: number | null;
  sourceQuality?: string | null;
  sourceHiRes?: boolean;
  isExplicit?: boolean | null;
  playbackSource?: string | null;
  playbackSourceType?: PlaybackSourceType | null;
  playbackSourceId?: string | null;
  feedbackToken?: string | null;
}

export class Song {
  videoId: string;
  title: string;
  artist: string;
  thumbnailUrl: string | null;
  durationText: string | null;
  artistId: string | null;
  artists: Array<ArtistRef>;
  albumId: string | null;
  albumName: string | null;
  isVideo: boolean;
  isVideoOrigin: boolean;
  setVideoId: string | null;
  queueTier: QueueTier;
  queueEntryId: string | null;
  radioName: string | null;
  localUri: string | null;
  downloadFormat: string | null;
  localPath: string | null;
  localDateAddedSeconds: number | null;
  localDateModifiedSeconds: number | null;
  trackNumber: number | null;
  sourceQuality: string | null;
  sourceHiRes: boolean;
  isExplicit: boolean | null;
  playbackSource: string | null;
  playbackSourceType: PlaybackSourceType | null;
  playbackSourceId: string | null;
  feedbackToken: string | null;

  constructor(
    videoId: string,
    title: string,
    artist: string,
    thumbnailUrl: string | null,
    options?: SongOptions
  ) {
    this.videoId = videoId;
    this.title = title;
    this.artist = artist;
    this.thumbnailUrl = thumbnailUrl;
    this.durationText = (options !== undefined && options.durationText !== undefined) ? options.durationText : null;
    this.artistId = (options !== undefined && options.artistId !== undefined) ? options.artistId : null;
    this.artists = (options !== undefined && options.artists !== undefined) ? options.artists : [];
    this.albumId = (options !== undefined && options.albumId !== undefined) ? options.albumId : null;
    this.albumName = (options !== undefined && options.albumName !== undefined) ? options.albumName : null;
    this.isVideo = (options !== undefined && options.isVideo !== undefined) ? options.isVideo : false;
    this.isVideoOrigin = (options !== undefined && options.isVideoOrigin !== undefined) ? options.isVideoOrigin : this.isVideo;
    this.setVideoId = (options !== undefined && options.setVideoId !== undefined) ? options.setVideoId : null;
    this.queueTier = (options !== undefined && options.queueTier !== undefined) ? options.queueTier : QueueTier.CONTEXT;
    this.queueEntryId = (options !== undefined && options.queueEntryId !== undefined) ? options.queueEntryId : null;
    this.radioName = (options !== undefined && options.radioName !== undefined) ? options.radioName : null;
    this.localUri = (options !== undefined && options.localUri !== undefined) ? options.localUri : null;
    this.downloadFormat = (options !== undefined && options.downloadFormat !== undefined) ? options.downloadFormat : null;
    this.localPath = (options !== undefined && options.localPath !== undefined) ? options.localPath : null;
    this.localDateAddedSeconds = (options !== undefined && options.localDateAddedSeconds !== undefined) ? options.localDateAddedSeconds : null;
    this.localDateModifiedSeconds = (options !== undefined && options.localDateModifiedSeconds !== undefined) ? options.localDateModifiedSeconds : null;
    this.trackNumber = (options !== undefined && options.trackNumber !== undefined) ? options.trackNumber : null;
    this.sourceQuality = (options !== undefined && options.sourceQuality !== undefined) ? options.sourceQuality : null;
    this.sourceHiRes = (options !== undefined && options.sourceHiRes !== undefined) ? options.sourceHiRes : false;
    this.isExplicit = (options !== undefined && options.isExplicit !== undefined) ? options.isExplicit : null;
    this.playbackSource = (options !== undefined && options.playbackSource !== undefined) ? options.playbackSource : null;
    this.playbackSourceType = (options !== undefined && options.playbackSourceType !== undefined) ? options.playbackSourceType : null;
    this.playbackSourceId = (options !== undefined && options.playbackSourceId !== undefined) ? options.playbackSourceId : null;
    this.feedbackToken = (options !== undefined && options.feedbackToken !== undefined) ? options.feedbackToken : null;
  }

  get fromAutoplay(): boolean {
    return this.queueTier === QueueTier.AUTOPLAY;
  }

  artworkAt(px: number): string | null {
    return artworkUrlAt(this.thumbnailUrl, px);
  }

  durationMillis(): number {
    return parseDurationTextMillis(this.durationText);
  }

  isSameTrackAs(other: Song | null): boolean {
    if (other === null) {
      return false;
    }
    return this.title === other.title && this.artist === other.artist;
  }

  withIsVideo(isVideo: boolean): Song {
    return new Song(this.videoId, this.title, this.artist, this.thumbnailUrl, {
      durationText: this.durationText,
      artistId: this.artistId,
      artists: this.artists,
      albumId: this.albumId,
      albumName: this.albumName,
      isVideo: isVideo,
      isVideoOrigin: this.isVideoOrigin,
      setVideoId: this.setVideoId,
      queueTier: this.queueTier,
      queueEntryId: this.queueEntryId,
      radioName: this.radioName,
      localUri: this.localUri,
      downloadFormat: this.downloadFormat,
      localPath: this.localPath,
      localDateAddedSeconds: this.localDateAddedSeconds,
      localDateModifiedSeconds: this.localDateModifiedSeconds,
      trackNumber: this.trackNumber,
      sourceQuality: this.sourceQuality,
      sourceHiRes: this.sourceHiRes,
      isExplicit: this.isExplicit,
      playbackSource: this.playbackSource,
      playbackSourceType: this.playbackSourceType,
      playbackSourceId: this.playbackSourceId,
      feedbackToken: this.feedbackToken,
    });
  }
}

const SIZE_HINT_REGEX: RegExp = /w\d+-h\d+/g;
const PARAM_SIZE_HINT_REGEX: RegExp = /=s\d+/g;

function isGoogleImageHost(url: string): boolean {
  const host = extractUrlHost(url);
  return (
    host === 'ggpht.com' ||
    host.endsWith('.ggpht.com') ||
    host === 'googleusercontent.com' ||
    host.endsWith('.googleusercontent.com')
  );
}

/** Thay đổi kích thước ảnh bìa từ CDN của YouTube/Google (`w<px>-h<px>` hoặc `=s<px>`). */
export function artworkUrlAt(url: string | null | undefined, px: number): string | null {
  if (url === null || url === undefined) {
    return null;
  }
  const sized = url.replace(SIZE_HINT_REGEX, `w${px}-h${px}`);
  if (isGoogleImageHost(url)) {
    return sized.replace(PARAM_SIZE_HINT_REGEX, `=s${px}`);
  }
  return sized;
}

/** Chuyển chuỗi thời lượng "M:SS" hoặc "H:MM:SS" sang mili-giây (trả về 0 nếu không hợp lệ). */
export function parseDurationTextMillis(durationText: string | null | undefined): number {
  if (durationText === null || durationText === undefined) {
    return 0;
  }
  const trimmed = durationText.trim();
  if (trimmed.length === 0) {
    return 0;
  }
  const parts = trimmed.split(':');
  const numbers: Array<number> = [];
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i].trim();
    if (!/^\d+$/.test(p)) {
      return 0;
    }
    numbers.push(Number(p));
  }
  let seconds = 0;
  if (numbers.length === 2) {
    seconds = numbers[0] * 60 + numbers[1];
  } else if (numbers.length === 3) {
    seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2];
  } else {
    return 0;
  }
  return Math.max(0, seconds * 1000);
}

export const ROW_ART_PX: number = 160;
export const CARD_ART_PX: number = 480;
export const HEADER_ART_PX: number = 720;
export const NOTIFICATION_ART_PX: number = 544;
export const PLAYER_ART_PX: number = 1200;

export class BrowseItem {
  browseId: string;
  title: string;
  subtitle: string;
  thumbnailUrl: string | null;
  type: BrowseType;

  constructor(
    browseId: string,
    title: string,
    subtitle: string,
    thumbnailUrl: string | null,
    type: BrowseType
  ) {
    this.browseId = browseId;
    this.title = title;
    this.subtitle = subtitle;
    this.thumbnailUrl = thumbnailUrl;
    this.type = type;
  }
}

export class SearchResult {
  /** 'top_track' | 'track' | 'browse' */
  kind: string;
  song: Song | null;
  item: BrowseItem | null;

  constructor(kind: string, song: Song | null = null, item: BrowseItem | null = null) {
    this.kind = kind;
    this.song = song;
    this.item = item;
  }

  static topTrack(song: Song): SearchResult {
    return new SearchResult('top_track', song, null);
  }

  static track(song: Song): SearchResult {
    return new SearchResult('track', song, null);
  }

  static browse(item: BrowseItem): SearchResult {
    return new SearchResult('browse', null, item);
  }
}

export class ShelfItem {
  title: string;
  subtitle: string;
  thumbnailUrl: string | null;
  videoId: string | null;
  browseId: string | null;
  isVideo: boolean;

  constructor(
    title: string,
    subtitle: string,
    thumbnailUrl: string | null,
    videoId: string | null,
    browseId: string | null,
    isVideo: boolean = false
  ) {
    this.title = title;
    this.subtitle = subtitle;
    this.thumbnailUrl = thumbnailUrl;
    this.videoId = videoId;
    this.browseId = browseId;
    this.isVideo = isVideo;
  }
}

export class HomeShelf {
  title: string;
  items: Array<ShelfItem>;
  subtitle: string;
  moreBrowseId: string | null;
  moreParams: string | null;
  layout: ShelfLayout;

  constructor(
    title: string,
    items: Array<ShelfItem>,
    subtitle: string = '',
    moreBrowseId: string | null = null,
    moreParams: string | null = null,
    layout: ShelfLayout = ShelfLayout.CARDS
  ) {
    this.title = title;
    this.items = items;
    this.subtitle = subtitle;
    this.moreBrowseId = moreBrowseId;
    this.moreParams = moreParams;
    this.layout = layout;
  }
}

export function shelfLayoutFor(title: string, items: Array<ShelfItem>, fromList: boolean): ShelfLayout {
  if (items.length === 0) {
    return ShelfLayout.CARDS;
  }
  const first = items[0];
  if (fromList && first.videoId !== null) {
    return ShelfLayout.LIST;
  }
  if (title.trim().toLowerCase() === 'listen again') {
    return ShelfLayout.LIST;
  }
  let videoCount = 0;
  for (let i = 0; i < items.length; i++) {
    if (items[i].isVideo) {
      videoCount++;
    }
  }
  if (videoCount * 2 > items.length) {
    return ShelfLayout.VIDEO;
  }
  return ShelfLayout.CARDS;
}

export class MoodGenre {
  title: string;
  browseId: string;
  params: string | null;
  thumbnailUrl: string | null;
  stripeColor: number | null;

  constructor(
    title: string,
    browseId: string,
    params: string | null,
    thumbnailUrl: string | null = null,
    stripeColor: number | null = null
  ) {
    this.title = title;
    this.browseId = browseId;
    this.params = params;
    this.thumbnailUrl = thumbnailUrl;
    this.stripeColor = stripeColor;
  }
}

export class MoodGenreSection {
  title: string;
  items: Array<MoodGenre>;

  constructor(title: string, items: Array<MoodGenre>) {
    this.title = title;
    this.items = items;
  }
}

export class Account {
  name: string;
  email: string;
  thumbnailUrl: string | null;

  constructor(name: string, email: string, thumbnailUrl: string | null) {
    this.name = name;
    this.email = email;
    this.thumbnailUrl = thumbnailUrl;
  }
}

export class AccountChannel {
  name: string;
  subtitle: string;
  thumbnailUrl: string | null;
  pageId: string | null;
  dataSyncId: string | null;
  activeOnWeb: boolean;

  constructor(
    name: string,
    subtitle: string,
    thumbnailUrl: string | null,
    pageId: string | null,
    dataSyncId: string | null,
    activeOnWeb: boolean
  ) {
    this.name = name;
    this.subtitle = subtitle;
    this.thumbnailUrl = thumbnailUrl;
    this.pageId = pageId;
    this.dataSyncId = dataSyncId;
    this.activeOnWeb = activeOnWeb;
  }

  get key(): string {
    if (this.pageId !== null) {
      return this.pageId;
    }
    if (this.dataSyncId !== null) {
      return this.dataSyncId;
    }
    return this.name;
  }
}

export class LibraryState {
  playlistId: string;
  saved: boolean;

  constructor(playlistId: string, saved: boolean) {
    this.playlistId = playlistId;
    this.saved = saved;
  }
}

export class SubscriptionState {
  channelId: string;
  subscribed: boolean;

  constructor(channelId: string, subscribed: boolean) {
    this.channelId = channelId;
    this.subscribed = subscribed;
  }
}

export class WatchTarget {
  playlistId: string;
  videoId: string | null;
  params: string | null;

  constructor(playlistId: string, videoId: string | null = null, params: string | null = null) {
    this.playlistId = playlistId;
    this.videoId = videoId;
    this.params = params;
  }
}

export class ArtistPage {
  songs: Array<Song>;
  moreSongsBrowseId: string | null;
  sections: Array<HomeShelf>;
  thumbnailUrl: string | null;
  name: string | null;
  description: string | null;
  subscriberCountText: string | null;
  monthlyListenerCount: string | null;
  subscription: SubscriptionState | null;
  radio: WatchTarget | null;
  shuffle: WatchTarget | null;

  constructor(
    songs: Array<Song>,
    moreSongsBrowseId: string | null,
    sections: Array<HomeShelf>,
    thumbnailUrl: string | null = null,
    name: string | null = null,
    description: string | null = null,
    subscriberCountText: string | null = null,
    monthlyListenerCount: string | null = null,
    subscription: SubscriptionState | null = null,
    radio: WatchTarget | null = null,
    shuffle: WatchTarget | null = null
  ) {
    this.songs = songs;
    this.moreSongsBrowseId = moreSongsBrowseId;
    this.sections = sections;
    this.thumbnailUrl = thumbnailUrl;
    this.name = name;
    this.description = description;
    this.subscriberCountText = subscriberCountText;
    this.monthlyListenerCount = monthlyListenerCount;
    this.subscription = subscription;
    this.radio = radio;
    this.shuffle = shuffle;
  }
}

export class UserPlaylist {
  playlistId: string;
  title: string;
  subtitle: string;
  thumbnailUrl: string | null;

  constructor(playlistId: string, title: string, subtitle: string, thumbnailUrl: string | null) {
    this.playlistId = playlistId;
    this.title = title;
    this.subtitle = subtitle;
    this.thumbnailUrl = thumbnailUrl;
  }

  get browseId(): string {
    return `VL${this.playlistId}`;
  }
}

export class PlaylistMove {
  setVideoId: string;
  before: string | null;

  constructor(setVideoId: string, before: string | null = null) {
    this.setVideoId = setVideoId;
    this.before = before;
  }
}

export class SongMenu {
  likeStatus: LikeStatus | null;
  inLibrary: boolean;
  addToLibraryToken: string | null;
  removeFromLibraryToken: string | null;

  constructor(
    likeStatus: LikeStatus | null,
    inLibrary: boolean,
    addToLibraryToken: string | null,
    removeFromLibraryToken: string | null
  ) {
    this.likeStatus = likeStatus;
    this.inLibrary = inLibrary;
    this.addToLibraryToken = addToLibraryToken;
    this.removeFromLibraryToken = removeFromLibraryToken;
  }
}

export class VersionTimeSegment {
  fromStartMs: number;
  toStartMs: number;
  durationMs: number;

  constructor(fromStartMs: number, toStartMs: number, durationMs: number) {
    this.fromStartMs = fromStartMs;
    this.toStartMs = toStartMs;
    this.durationMs = durationMs;
  }
}

export class VersionTimeMap {
  segments: Array<VersionTimeSegment>;

  constructor(segments: Array<VersionTimeSegment>) {
    this.segments = segments.slice().sort((a: VersionTimeSegment, b: VersionTimeSegment): number => {
      return a.fromStartMs - b.fromStartMs;
    });
  }

  map(positionMs: number): number {
    for (let i = 0; i < this.segments.length; i++) {
      const seg = this.segments[i];
      if (positionMs < seg.fromStartMs) {
        return seg.toStartMs;
      }
      const into = positionMs - seg.fromStartMs;
      if (into < seg.durationMs) {
        return seg.toStartMs + into;
      }
    }
    const last = this.segments[this.segments.length - 1];
    return last.toStartMs + last.durationMs;
  }

  inverted(): VersionTimeMap {
    const inv: Array<VersionTimeSegment> = [];
    for (let i = 0; i < this.segments.length; i++) {
      const s = this.segments[i];
      inv.push(new VersionTimeSegment(s.toStartMs, s.fromStartMs, s.durationMs));
    }
    return new VersionTimeMap(inv);
  }
}

export class VersionPair {
  song: Song;
  timeMap: VersionTimeMap | null;

  constructor(song: Song, timeMap: VersionTimeMap | null) {
    this.song = song;
    this.timeMap = timeMap;
  }
}

export class PlaybackTracking {
  playbackUrl: string;
  watchtimeUrl: string | null;
  atrUrl: string | null;
  atrAfterSeconds: number;

  constructor(
    playbackUrl: string,
    watchtimeUrl: string | null,
    atrUrl: string | null,
    atrAfterSeconds: number
  ) {
    this.playbackUrl = playbackUrl;
    this.watchtimeUrl = watchtimeUrl;
    this.atrUrl = atrUrl;
    this.atrAfterSeconds = atrAfterSeconds;
  }
}

// ---- ArtistCredits.kt (Chuẩn hóa & khôi phục liên kết nghệ sĩ từ bộ nhớ đệm) -----------------

const COMBINING_MARKS_REGEX: RegExp = /[\u0300-\u036f]+/g;
const REPEATED_SPACE_REGEX: RegExp = /\s+/g;
const CREDIT_JOINER_REGEX: RegExp = /\s*,\s*|\s*，\s*|\s+&\s+|\s+＆\s+|\s*•\s*|\s*·\s*|\s*・\s*|\s*、\s*/g;
const JOINER_WORD_SIGHTINGS: number = 2;

export function normalizedArtistName(raw: string): string {
  return raw
    .normalize('NFD')
    .replace(COMBINING_MARKS_REGEX, '')
    .toLowerCase()
    .replace(REPEATED_SPACE_REGEX, ' ')
    .trim();
}

export function isExactArtistMatch(answer: string, wanted: string): boolean {
  const name = normalizedArtistName(wanted);
  if (name.length === 0) {
    return false;
  }
  return normalizedArtistName(answer) === name;
}

export class CreditSegment {
  text: string;
  credit: ArtistRef | null;

  constructor(text: string, credit: ArtistRef | null = null) {
    this.text = text;
    this.credit = credit;
  }
}

export function creditSegments(text: string, credits: Array<ArtistRef>): Array<CreditSegment> {
  if (text.length === 0) {
    return [];
  }
  const seenKeys: Array<string> = [];
  const names: Array<ArtistRef> = [];
  for (let i = 0; i < credits.length; i++) {
    const c = credits[i];
    if (c.name.trim().length === 0) {
      continue;
    }
    const key = normalizedArtistName(c.name);
    if (!seenKeys.includes(key)) {
      seenKeys.push(key);
      names.push(c);
    }
  }
  names.sort((a: ArtistRef, b: ArtistRef): number => b.name.length - a.name.length);
  if (names.length === 0) {
    return [new CreditSegment(text, null)];
  }

  const out: Array<CreditSegment> = [];
  let plain = '';
  let index = 0;
  while (index < text.length) {
    let hit: ArtistRef | null = null;
    for (let i = 0; i < names.length; i++) {
      const candidate = names[i];
      if (text.slice(index, index + candidate.name.length).toLowerCase() === candidate.name.toLowerCase()) {
        hit = candidate;
        break;
      }
    }
    if (hit === null) {
      plain += text.charAt(index);
      index++;
      continue;
    }
    if (plain.length > 0) {
      out.push(new CreditSegment(plain, null));
      plain = '';
    }
    out.push(new CreditSegment(text.slice(index, index + hit.name.length), hit));
    index += hit.name.length;
  }
  if (plain.length > 0) {
    out.push(new CreditSegment(plain, null));
  }
  return out;
}

export class ArtistNameIndex {
  private static channels: Map<string, Array<string>> = new Map<string, Array<string>>();
  private static joiners: Array<string> = [];
  private static joinerTextsSet: Array<string> = [];
  private static joinerSightings: Map<string, number> = new Map<string, number>();

  static record(refs: Array<ArtistRef>): void {
    for (let i = 0; i < refs.length; i++) {
      const ref = refs[i];
      const name = normalizedArtistName(ref.name);
      const id = ref.browseId;
      if (name.length === 0 || id === null || id.trim().length === 0) {
        continue;
      }
      let existing = ArtistNameIndex.channels.get(name);
      if (existing === undefined) {
        existing = [];
        ArtistNameIndex.channels.set(name, existing);
      }
      if (!existing.includes(id)) {
        existing.push(id);
      }
    }
  }

  static recordJoiners(segments: Array<CreditSegment>): void {
    const creditIndices: Array<number> = [];
    for (let i = 0; i < segments.length; i++) {
      if (segments[i].credit !== null) {
        creditIndices.push(i);
      }
    }
    if (creditIndices.length < 2) {
      return;
    }
    const first = creditIndices[0];
    const last = creditIndices[creditIndices.length - 1];
    for (let index = first + 1; index <= last; index++) {
      const segment = segments[index];
      if (segment.credit !== null) {
        continue;
      }
      const key = normalizedArtistName(segment.text);
      if (key.length === 0) {
        continue;
      }
      if (/[\p{L}\p{N}]/u.test(segment.text)) {
        if (/\s/.test(key) || /\d/.test(key)) {
          continue;
        }
        const prevCount = ArtistNameIndex.joinerSightings.get(key);
        const seen = (prevCount !== undefined ? prevCount : 0) + 1;
        ArtistNameIndex.joinerSightings.set(key, seen);
        if (seen < JOINER_WORD_SIGHTINGS) {
          continue;
        }
      }
      if (!ArtistNameIndex.joiners.includes(key)) {
        ArtistNameIndex.joiners.push(key);
      }
      const trimmed = segment.text.trim();
      if (trimmed.length > 0 && !ArtistNameIndex.joinerTextsSet.includes(trimmed)) {
        ArtistNameIndex.joinerTextsSet.push(trimmed);
      }
    }
  }

  static lookup(name: string): string | null {
    const ids = ArtistNameIndex.channels.get(normalizedArtistName(name));
    if (ids === undefined || ids.length !== 1) {
      return null;
    }
    return ids[0];
  }

  static isJoiner(text: string): boolean {
    return ArtistNameIndex.joiners.includes(normalizedArtistName(text));
  }

  static joinerTexts(): Array<string> {
    return ArtistNameIndex.joinerTextsSet;
  }

  static forget(): void {
    ArtistNameIndex.channels.clear();
    ArtistNameIndex.joiners = [];
    ArtistNameIndex.joinerTextsSet = [];
    ArtistNameIndex.joinerSightings.clear();
  }
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function buildFragmentCutter(): RegExp {
  const words = ArtistNameIndex.joinerTexts();
  if (words.length === 0) {
    return CREDIT_JOINER_REGEX;
  }
  const anchored: Array<string> = [];
  for (let i = 0; i < words.length; i++) {
    const w = words[i].trim();
    if (w.length > 0) {
      anchored.push(`(?:^|(?<=\\s))\\s*${escapeRegExp(w)}\\s*(?=\\s|$)`);
    }
  }
  anchored.push(CREDIT_JOINER_REGEX.source);
  return new RegExp(anchored.join('|'), 'gi');
}

export function completeArtistCredits(lineText: string, stated: Array<ArtistRef>): Array<ArtistRef> {
  if (lineText.trim().length === 0 || stated.length === 0) {
    return stated;
  }
  const named: Array<ArtistRef> = [];
  for (let i = 0; i < stated.length; i++) {
    if (stated[i].name.trim().length > 0) {
      named.push(stated[i]);
    }
  }
  const segments = creditSegments(lineText, named);
  ArtistNameIndex.recordJoiners(segments);

  const usedIds: Array<string> = [];
  for (let i = 0; i < named.length; i++) {
    const id = named[i].browseId;
    if (id !== null && !usedIds.includes(id)) {
      usedIds.push(id);
    }
  }

  const cutter = buildFragmentCutter();
  const out: Array<ArtistRef> = [];
  const placedNames: Array<string> = [];

  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i];
    if (segment.credit !== null) {
      let matchedRef: ArtistRef | null = null;
      for (let j = 0; j < named.length; j++) {
        if (named[j].name.toLowerCase() === segment.credit.name.toLowerCase()) {
          matchedRef = named[j];
          break;
        }
      }
      const ref = matchedRef !== null ? matchedRef : new ArtistRef(segment.credit.name, segment.credit.browseId);
      const normKey = normalizedArtistName(ref.name);
      if (!placedNames.includes(normKey)) {
        placedNames.push(normKey);
        out.push(ref);
      }
      continue;
    }
    const rawFragments = segment.text.split(cutter);
    for (let j = 0; j < rawFragments.length; j++) {
      const frag = rawFragments[j].trim();
      if (frag.length === 0 || ArtistNameIndex.isJoiner(frag)) {
        continue;
      }
      const id = ArtistNameIndex.lookup(frag);
      if (id === null || usedIds.includes(id)) {
        continue;
      }
      usedIds.push(id);
      const normFrag = normalizedArtistName(frag);
      if (!placedNames.includes(normFrag)) {
        placedNames.push(normFrag);
        out.push(new ArtistRef(frag, id));
      }
    }
  }

  for (let i = 0; i < named.length; i++) {
    const ref = named[i];
    const normKey = normalizedArtistName(ref.name);
    if (!placedNames.includes(normKey)) {
      placedNames.push(normKey);
      out.push(ref);
    }
  }
  return out;
}

// ============================================================================
// 5. InnertubeParser.kt (Bộ phân tích JSON đệ quy & an toàn cho YouTube Music)
// ============================================================================

function jsonObj(node: Object | null | undefined, key: string): JsonRecord | null {
  const rec = asJsonRecord(node);
  if (rec === null) {
    return null;
  }
  return asJsonRecord(getRecordField(rec, key));
}

function jsonArr(node: Object | null | undefined, key: string): Array<Object | null | undefined> | null {
  const rec = asJsonRecord(node);
  if (rec === null) {
    return null;
  }
  return asJsonArray(getRecordField(rec, key));
}

function jsonStr(node: Object | null | undefined, key: string): string | null {
  const rec = asJsonRecord(node);
  if (rec === null) {
    return null;
  }
  const val = getRecordField(rec, key);
  if (typeof val === 'string') {
    return val;
  }
  if (typeof val === 'number' || typeof val === 'boolean') {
    return String(val);
  }
  return null;
}

function jsonRunsText(node: Object | null | undefined): string {
  const runs = jsonArr(node, 'runs');
  if (runs === null) {
    return '';
  }
  let out = '';
  for (let i = 0; i < runs.length; i++) {
    const t = jsonStr(runs[i], 'text');
    if (t !== null) {
      out += t;
    }
  }
  return out;
}

function jsonFirstRunText(node: Object | null | undefined): string | null {
  const runs = jsonArr(node, 'runs');
  if (runs === null || runs.length === 0) {
    return null;
  }
  return jsonStr(runs[0], 'text');
}

function jsonFindStringDeep(node: Object | null | undefined, key: string): string | null {
  const rec = asJsonRecord(node);
  if (rec !== null) {
    const direct = getStringField(rec, key);
    if (direct !== null) {
      return direct;
    }
    const keys = Object.keys(rec);
    for (let i = 0; i < keys.length; i++) {
      const found = jsonFindStringDeep(rec[keys[i]], key);
      if (found !== null) {
        return found;
      }
    }
    return null;
  }
  const arr = asJsonArray(node);
  if (arr !== null) {
    for (let i = 0; i < arr.length; i++) {
      const found = jsonFindStringDeep(arr[i], key);
      if (found !== null) {
        return found;
      }
    }
  }
  return null;
}

function jsonHasKeyDeep(node: Object | null | undefined, key: string): boolean {
  const rec = asJsonRecord(node);
  if (rec !== null) {
    const keys = Object.keys(rec);
    if (keys.includes(key)) {
      return true;
    }
    for (let i = 0; i < keys.length; i++) {
      if (jsonHasKeyDeep(rec[keys[i]], key)) {
        return true;
      }
    }
    return false;
  }
  const arr = asJsonArray(node);
  if (arr !== null) {
    for (let i = 0; i < arr.length; i++) {
      if (jsonHasKeyDeep(arr[i], key)) {
        return true;
      }
    }
  }
  return false;
}

function bestThumbnailUrl(thumbnails: Array<Object | null | undefined> | null): string | null {
  if (thumbnails === null || thumbnails.length === 0) {
    return null;
  }
  return jsonStr(thumbnails[thumbnails.length - 1], 'url');
}

function isThumbnailNotSquare(thumbnails: Array<Object | null | undefined> | null): boolean {
  if (thumbnails === null || thumbnails.length === 0) {
    return false;
  }
  const last = thumbnails[thumbnails.length - 1];
  const wStr = jsonStr(last, 'width');
  const hStr = jsonStr(last, 'height');
  if (wStr === null || hStr === null) {
    return false;
  }
  const w = Number(wStr);
  const h = Number(hStr);
  if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) {
    return false;
  }
  const ratio = w / h;
  return ratio < 0.85 || ratio > 1.15;
}

function hasExplicitBadgeDeep(node: Object | null | undefined): boolean | null {
  const check = (n: Object | null | undefined): boolean => {
    if (n === null || n === undefined) {
      return false;
    }
    if (typeof n === 'string') {
      return n === 'MUSIC_EXPLICIT_BADGE';
    }
    const arr = asJsonArray(n);
    if (arr !== null) {
      for (let i = 0; i < arr.length; i++) {
        if (check(arr[i])) {
          return true;
        }
      }
      return false;
    }
    const rec = asJsonRecord(n);
    if (rec !== null) {
      const keys = Object.keys(rec);
      for (let i = 0; i < keys.length; i++) {
        if (check(rec[keys[i]])) {
          return true;
        }
      }
    }
    return false;
  };
  return check(node) ? true : null;
}

export class CreditsInfo {
  artistId: string | null;
  artistName: string | null;
  artists: Array<ArtistRef>;
  albumId: string | null;
  albumName: string | null;

  constructor(
    artistId: string | null = null,
    artistName: string | null = null,
    artists: Array<ArtistRef> = [],
    albumId: string | null = null,
    albumName: string | null = null
  ) {
    this.artistId = artistId;
    this.artistName = artistName;
    this.artists = artists;
    this.albumId = albumId;
    this.albumName = albumName;
  }
}

export class BrowseHeader {
  title: string;
  subtitle: string;
  thumbnailUrl: string | null;

  constructor(title: string, subtitle: string, thumbnailUrl: string | null) {
    this.title = title;
    this.subtitle = subtitle;
    this.thumbnailUrl = thumbnailUrl;
  }
}

export class SearchPage {
  rows: Array<SearchResult>;
  continuation: string | null;

  constructor(rows: Array<SearchResult>, continuation: string | null) {
    this.rows = rows;
    this.continuation = continuation;
  }
}

export class PlaylistShelfPage {
  songs: Array<Song>;
  suggested: Array<Song>;
  continuation: string | null;

  constructor(songs: Array<Song>, suggested: Array<Song>, continuation: string | null) {
    this.songs = songs;
    this.suggested = suggested;
    this.continuation = continuation;
  }
}

export class LibraryItemPage {
  items: Array<ShelfItem>;
  continuation: string | null;

  constructor(items: Array<ShelfItem>, continuation: string | null) {
    this.items = items;
    this.continuation = continuation;
  }
}

class CardCreditPair {
  renderer: JsonRecord;
  credit: CreditsInfo;

  constructor(renderer: JsonRecord, credit: CreditsInfo) {
    this.renderer = renderer;
    this.credit = credit;
  }
}

const DURATION_REGEX: RegExp = /^\d+:\d{2}(?::\d{2})?$/;
const RUNTIME_PART_REGEX: RegExp = /(\d+)\s*(hours?|hr|min|sec)/gi;
const YEAR_REGEX: RegExp = /^\d{4}$/;
const TALLY_REGEX: RegExp = /^[\d.,]+\s*[KMB]?\s+(plays|views|likes|songs|tracks|subscribers|hours?|minutes?|seconds?)\b.*/i;
const VIDEO_WORD_REGEX: RegExp = /\bvideos?\b/i;

const RELEASE_WORDS: Array<string> = ['album', 'single', 'ep'];
const HEADER_RENDERERS: Array<string> = ['musicResponsiveHeaderRenderer', 'musicDetailHeaderRenderer'];
const HEADER_CREDIT_LINES: Array<string> = ['straplineTextOne', 'subtitle'];
const TYPE_WORDS: Array<string> = ['song', 'video', 'album', 'single', 'ep', 'artist', 'playlist', 'podcast', 'episode'];
const NOT_EDITABLE_PREFIXES: Array<string> = ['LM', 'SE', 'RD', 'OLAK', 'MPRE'];
const LIBRARY_ICONS: Array<string> = ['LIBRARY_ADD', 'LIBRARY_REMOVE', 'LIBRARY_SAVED'];
const OWNER_ICONS: Array<string> = ['DELETE', 'EDIT'];
const MUSIC_VIDEO_TYPE_ATV: string = 'MUSIC_VIDEO_TYPE_ATV';

export class InnertubeParser {
  /** Thu thập đệ quy theo chiều sâu tất cả các object con có tên key trùng với [name]. */
  static collectRenderers(root: Object | null | undefined, name: string): Array<JsonRecord> {
    const out: Array<JsonRecord> = [];
    const walk = (node: Object | null | undefined): void => {
      const rec = asJsonRecord(node);
      if (rec !== null) {
        const direct = asJsonRecord(getRecordField(rec, name));
        if (direct !== null) {
          out.push(direct);
        }
        const keys = Object.keys(rec);
        for (let i = 0; i < keys.length; i++) {
          walk(rec[keys[i]]);
        }
        return;
      }
      const arr = asJsonArray(node);
      if (arr !== null) {
        for (let i = 0; i < arr.length; i++) {
          walk(arr[i]);
        }
      }
    };
    walk(root);
    return out;
  }

  static parseSearchSongs(response: JsonRecord): Array<Song> {
    const all = InnertubeParser.parseSearch(response);
    const songs: Array<Song> = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].kind === 'track' && all[i].song !== null) {
        songs.push(all[i].song as Song);
      }
    }
    return songs;
  }

  static parseSearch(response: JsonRecord): Array<SearchResult> {
    return InnertubeParser.parseSearchPage(response, false).rows;
  }

  static parseSearchPage(response: JsonRecord, includeVideos: boolean = false): SearchPage {
    const topResults: Array<SearchResult> = [];
    if (!includeVideos) {
      const cards = InnertubeParser.collectRenderers(response, 'musicCardShelfRenderer');
      for (let i = 0; i < cards.length; i++) {
        const cardSong = InnertubeParser.parseCardShelfSong(cards[i]);
        if (cardSong !== null) {
          topResults.push(SearchResult.topTrack(cardSong));
        } else {
          const cardBrowse = InnertubeParser.parseCardShelfBrowse(cards[i]);
          if (cardBrowse !== null) {
            topResults.push(SearchResult.browse(cardBrowse));
          }
        }
      }
    }

    const rows = InnertubeParser.collectRenderers(response, 'musicResponsiveListItemRenderer');
    const cardCredits: Array<CardCreditPair> = [];
    if (!includeVideos) {
      const cards = InnertubeParser.collectRenderers(response, 'musicCardShelfRenderer');
      for (let i = 0; i < cards.length; i++) {
        const credit = InnertubeParser.cardShelfCredit(cards[i]);
        if (credit !== null) {
          const innerRows = InnertubeParser.collectRenderers(cards[i], 'musicResponsiveListItemRenderer');
          for (let j = 0; j < innerRows.length; j++) {
            cardCredits.push(new CardCreditPair(innerRows[j], credit));
          }
        }
      }
    }

    const seen: Array<string> = [];
    const parsed: Array<SearchResult> = [];

    for (let i = 0; i < topResults.length; i++) {
      const res = topResults[i];
      if (res.kind === 'top_track' && res.song !== null) {
        const key = `v:${res.song.videoId}`;
        if (!res.song.isVideo && !seen.includes(key)) {
          seen.push(key);
          parsed.push(res);
        }
      } else if (res.kind === 'browse' && res.item !== null) {
        const key = `b:${res.item.browseId}`;
        if (!seen.includes(key)) {
          seen.push(key);
          parsed.push(res);
        }
      }
    }

    for (let i = 0; i < rows.length; i++) {
      const renderer = rows[i];
      const browse = InnertubeParser.parseBrowseItem(renderer);
      if (browse !== null) {
        const key = `b:${browse.browseId}`;
        if (!seen.includes(key)) {
          seen.push(key);
          parsed.push(SearchResult.browse(browse));
        }
      } else {
        let fallback = new CreditsInfo();
        for (let j = 0; j < cardCredits.length; j++) {
          if (cardCredits[j].renderer === renderer) {
            fallback = cardCredits[j].credit;
            break;
          }
        }
        const song = InnertubeParser.parseResponsiveListItem(renderer, fallback);
        if (song !== null && song.isVideo === includeVideos) {
          const key = `v:${song.videoId}`;
          if (!seen.includes(key)) {
            seen.push(key);
            parsed.push(SearchResult.track(song));
          }
        }
      }
    }

    return new SearchPage(parsed, InnertubeParser.continuationToken(response));
  }

  static parseSearchSuggestions(response: JsonRecord): Array<string> {
    const renderers = InnertubeParser.collectRenderers(response, 'searchSuggestionRenderer');
    const out: Array<string> = [];
    for (let i = 0; i < renderers.length; i++) {
      const r = renderers[i];
      const navSearch = jsonObj(jsonObj(r, 'navigationEndpoint'), 'searchEndpoint');
      const queryFromEndpoint = jsonStr(navSearch, 'query');
      const query = queryFromEndpoint !== null ? queryFromEndpoint : jsonRunsText(jsonObj(r, 'suggestion'));
      const trimmed = query.trim();
      if (trimmed.length > 0 && !out.includes(trimmed)) {
        out.push(trimmed);
      }
    }
    return out;
  }

  static parseHome(response: JsonRecord): Array<HomeShelf> {
    const tabs = jsonArr(jsonObj(jsonObj(response, 'contents'), 'singleColumnBrowseResultsRenderer'), 'tabs');
    const firstTab = (tabs !== null && tabs.length > 0) ? tabs[0] : null;
    const sections = jsonArr(jsonObj(jsonObj(jsonObj(firstTab, 'tabRenderer'), 'content'), 'sectionListRenderer'), 'contents');
    if (sections === null) {
      return [];
    }
    const out: Array<HomeShelf> = [];
    for (let i = 0; i < sections.length; i++) {
      const sec = sections[i];
      const carousel = jsonObj(sec, 'musicCarouselShelfRenderer');
      if (carousel !== null) {
        const parsedCarousel = InnertubeParser.carouselShelf(carousel);
        if (parsedCarousel !== null) {
          out.push(parsedCarousel);
        }
        continue;
      }
      const plain = jsonObj(sec, 'musicShelfRenderer');
      if (plain !== null) {
        const parsedPlain = InnertubeParser.plainShelf(plain);
        if (parsedPlain !== null) {
          out.push(parsedPlain);
        }
        continue;
      }
      const playlist = jsonObj(sec, 'musicPlaylistShelfRenderer');
      if (playlist !== null) {
        const parsedPlaylist = InnertubeParser.plainShelf(playlist);
        if (parsedPlaylist !== null) {
          out.push(parsedPlaylist);
        }
        continue;
      }
      const grid = jsonObj(sec, 'gridRenderer');
      if (grid !== null) {
        const parsedGrid = InnertubeParser.gridShelf(grid);
        if (parsedGrid !== null) {
          out.push(parsedGrid);
        }
      }
    }
    return out;
  }

  static parseHomeContinuation(root: Object | null | undefined): Array<HomeShelf> {
    const out: Array<HomeShelf> = [];
    const walk = (node: Object | null | undefined): void => {
      const rec = asJsonRecord(node);
      if (rec !== null) {
        const carousel = asJsonRecord(getRecordField(rec, 'musicCarouselShelfRenderer'));
        if (carousel !== null) {
          const s = InnertubeParser.carouselShelf(carousel);
          if (s !== null) {
            out.push(s);
          }
        }
        const plain = asJsonRecord(getRecordField(rec, 'musicShelfRenderer'));
        if (plain !== null) {
          const s = InnertubeParser.plainShelf(plain);
          if (s !== null) {
            out.push(s);
          }
        }
        const keys = Object.keys(rec);
        for (let i = 0; i < keys.length; i++) {
          walk(rec[keys[i]]);
        }
        return;
      }
      const arr = asJsonArray(node);
      if (arr !== null) {
        for (let i = 0; i < arr.length; i++) {
          walk(arr[i]);
        }
      }
    };
    walk(root);
    return out;
  }

  static parseMoodAndGenres(response: JsonRecord): Array<MoodGenreSection> {
    const tabs = jsonArr(jsonObj(jsonObj(response, 'contents'), 'singleColumnBrowseResultsRenderer'), 'tabs');
    const firstTab = (tabs !== null && tabs.length > 0) ? tabs[0] : null;
    const sections = jsonArr(jsonObj(jsonObj(jsonObj(firstTab, 'tabRenderer'), 'content'), 'sectionListRenderer'), 'contents');
    if (sections === null) {
      return [];
    }
    const parsed: Array<MoodGenreSection> = [];
    for (let i = 0; i < sections.length; i++) {
      const grid = jsonObj(sections[i], 'gridRenderer');
      if (grid === null) {
        continue;
      }
      const title = jsonRunsText(jsonObj(jsonObj(grid, 'header'), 'gridHeaderRenderer') !== null
        ? jsonObj(jsonObj(jsonObj(grid, 'header'), 'gridHeaderRenderer'), 'title')
        : null);
      const rawItems = jsonArr(grid, 'items');
      const items: Array<MoodGenre> = [];
      if (rawItems !== null) {
        for (let j = 0; j < rawItems.length; j++) {
          const button = jsonObj(rawItems[j], 'musicNavigationButtonRenderer');
          if (button === null) {
            continue;
          }
          const clickBrowse = jsonObj(jsonObj(button, 'clickCommand'), 'browseEndpoint');
          const navBrowse = jsonObj(jsonObj(button, 'navigationEndpoint'), 'browseEndpoint');
          const endpoint = clickBrowse !== null ? clickBrowse : navBrowse;
          const browseId = jsonStr(endpoint, 'browseId');
          const label = jsonRunsText(jsonObj(button, 'buttonText')).trim();
          if (browseId === null || label.length === 0) {
            continue;
          }
          const colorStr = jsonStr(jsonObj(button, 'solid'), 'leftStripeColor');
          const stripeColor = (colorStr !== null && !Number.isNaN(Number(colorStr))) ? Number(colorStr) : null;
          items.push(new MoodGenre(label, browseId, jsonStr(endpoint, 'params'), null, stripeColor));
        }
      }
      if (title.trim().length > 0 && items.length > 0) {
        parsed.push(new MoodGenreSection(title, items));
      }
    }

    const filtered: Array<MoodGenreSection> = [];
    for (let index = 0; index < parsed.length; index++) {
      const section = parsed[index];
      const laterKeys: Array<string> = [];
      for (let k = index + 1; k < parsed.length; k++) {
        const laterSec = parsed[k];
        for (let m = 0; m < laterSec.items.length; m++) {
          const it = laterSec.items[m];
          laterKeys.push(`${it.browseId}|${it.params !== null ? it.params : ''}`);
        }
      }
      let isShortcut = false;
      for (let m = 0; m < section.items.length; m++) {
        const it = section.items[m];
        if (laterKeys.includes(`${it.browseId}|${it.params !== null ? it.params : ''}`)) {
          isShortcut = true;
          break;
        }
      }
      if (!isShortcut && section.title.toLowerCase() !== 'for you') {
        filtered.push(section);
      }
    }
    return filtered;
  }

  static parseArtistPage(response: JsonRecord): ArtistPage {
    const tabs = jsonArr(jsonObj(jsonObj(response, 'contents'), 'singleColumnBrowseResultsRenderer'), 'tabs');
    const firstTab = (tabs !== null && tabs.length > 0) ? tabs[0] : null;
    const sections = jsonArr(jsonObj(jsonObj(jsonObj(firstTab, 'tabRenderer'), 'content'), 'sectionListRenderer'), 'contents');
    const songs: Array<Song> = [];
    let moreSongs: string | null = null;
    const shelves: Array<HomeShelf> = [];
    const header = getRecordField(response, 'header');
    const credit = new CreditsInfo(null, InnertubeParser.artistNameFromHeader(header));

    if (sections !== null) {
      for (let i = 0; i < sections.length; i++) {
        const section = sections[i];
        const shelf = jsonObj(section, 'musicShelfRenderer');
        if (shelf !== null) {
          const contents = jsonArr(shelf, 'contents');
          if (contents !== null) {
            for (let j = 0; j < contents.length; j++) {
              const s = InnertubeParser.parseResponsiveListItem(jsonObj(contents[j], 'musicResponsiveListItemRenderer'), credit);
              if (s !== null) {
                songs.push(s);
              }
            }
          }
          if (moreSongs === null) {
            const titleRuns = jsonArr(jsonObj(shelf, 'title'), 'runs');
            if (titleRuns !== null && titleRuns.length > 0) {
              moreSongs = jsonStr(jsonObj(jsonObj(titleRuns[0], 'navigationEndpoint'), 'browseEndpoint'), 'browseId');
            }
          }
        }
        const carousel = jsonObj(section, 'musicCarouselShelfRenderer');
        if (carousel !== null) {
          const cHeader = jsonObj( jsonObj(carousel, 'header'), 'musicCarouselShelfBasicHeaderRenderer');
          const title = jsonRunsText(jsonObj(cHeader, 'title'));
          const contents = jsonArr(carousel, 'contents');
          const items: Array<ShelfItem> = [];
          if (contents !== null) {
            for (let j = 0; j < contents.length; j++) {
              const twoRow = InnertubeParser.parseTwoRowItem(jsonObj(contents[j], 'musicTwoRowItemRenderer'));
              if (twoRow !== null && (twoRow.browseId !== null || twoRow.isVideo)) {
                items.push(twoRow);
              }
            }
          }
          const moreEndpoint = InnertubeParser.extractCarouselMoreEndpoint(cHeader);
          const moreBrowseId = jsonStr(moreEndpoint, 'browseId');
          const moreParams = jsonStr(moreEndpoint, 'params');
          if (title.trim().length > 0 && items.length > 0) {
            shelves.push(new HomeShelf(
              title,
              items,
              '',
              moreBrowseId,
              moreParams,
              shelfLayoutFor(title, items, false)
            ));
          }
        }
      }
    }

    return new ArtistPage(
      songs,
      moreSongs,
      shelves,
      InnertubeParser.artistThumbnailFromHeader(header),
      credit.artistName,
      InnertubeParser.parseDescription(response),
      InnertubeParser.subscriberCountFromHeader(header),
      InnertubeParser.monthlyListenersFromHeader(header),
      InnertubeParser.subscriptionFromHeader(header),
      InnertubeParser.headerWatchTarget(header, 'startRadioButton'),
      InnertubeParser.headerWatchTarget(header, 'playButton')
    );
  }

  static collectSongsDeep(root: Object | null | undefined, show: string | null = null): Array<Song> {
    const outMap: Map<string, Song> = new Map<string, Song>();
    const pageCredit = InnertubeParser.pageCredit(root);

    const walk = (node: Object | null | undefined): void => {
      const rec = asJsonRecord(node);
      if (rec !== null) {
        const respItem = asJsonRecord(getRecordField(rec, 'musicResponsiveListItemRenderer'));
        if (respItem !== null) {
          const s = InnertubeParser.parseResponsiveListItem(respItem, pageCredit);
          if (s !== null) {
            outMap.set(s.videoId, s);
          }
        }
        const multiItem = asJsonRecord(getRecordField(rec, 'musicMultiRowListItemRenderer'));
        if (multiItem !== null) {
          const s = InnertubeParser.parseMultiRowListItem(multiItem, show);
          if (s !== null) {
            outMap.set(s.videoId, s);
          }
        }
        const keys = Object.keys(rec);
        for (let i = 0; i < keys.length; i++) {
          walk(rec[keys[i]]);
        }
        return;
      }
      const arr = asJsonArray(node);
      if (arr !== null) {
        for (let i = 0; i < arr.length; i++) {
          walk(arr[i]);
        }
      }
    };

    walk(root);
    return Array.from(outMap.values());
  }

  static parsePlaylistShelf(root: Object | null | undefined): PlaylistShelfPage | null {
    const contContents = jsonObj(root, 'continuationContents');
    const secContents = jsonObj(jsonObj(jsonObj(root, 'contents'), 'twoColumnBrowseResultsRenderer'), 'secondaryContents');
    const scope = contContents !== null ? contContents : secContents;
    if (scope === null) {
      return null;
    }

    const contShelf = jsonObj(scope, 'musicPlaylistShelfContinuation');
    const foundShelves = InnertubeParser.collectRenderers(scope, 'musicPlaylistShelfRenderer');
    const playlistScope = contShelf !== null ? contShelf : (foundShelves.length > 0 ? foundShelves[0] : null);

    const allMusicShelves = InnertubeParser.collectRenderers(scope, 'musicShelfRenderer');
    const suggestionShelves: Array<JsonRecord> = [];
    for (let i = 0; i < allMusicShelves.length; i++) {
      if (jsonRunsText(jsonObj(allMusicShelves[i], 'title')) === 'Suggestions') {
        suggestionShelves.push(allMusicShelves[i]);
      }
    }
    if (playlistScope === null && suggestionShelves.length === 0) {
      return null;
    }

    const pageCredit = InnertubeParser.pageCredit(root);
    const songs: Array<Song> = [];
    const knownVideoIds: Array<string> = [];
    if (playlistScope !== null) {
      const rows = InnertubeParser.collectRenderers(playlistScope, 'musicResponsiveListItemRenderer');
      for (let i = 0; i < rows.length; i++) {
        const s = InnertubeParser.parseResponsiveListItem(rows[i], pageCredit);
        if (s !== null && !knownVideoIds.includes(s.videoId)) {
          knownVideoIds.push(s.videoId);
          songs.push(s);
        }
      }
    }

    const suggested: Array<Song> = [];
    const suggestedIds: Array<string> = [];
    for (let i = 0; i < suggestionShelves.length; i++) {
      const rows = InnertubeParser.collectRenderers(suggestionShelves[i], 'musicResponsiveListItemRenderer');
      for (let j = 0; j < rows.length; j++) {
        const s = InnertubeParser.parseResponsiveListItem(rows[j], pageCredit);
        if (s !== null && !knownVideoIds.includes(s.videoId) && !suggestedIds.includes(s.videoId)) {
          suggestedIds.push(s.videoId);
          suggested.push(s);
        }
      }
    }

    const token = playlistScope !== null ? InnertubeParser.continuationToken(playlistScope) : null;
    return new PlaylistShelfPage(songs, suggested, token);
  }

  static parseLibraryItems(root: Object | null | undefined): Array<ShelfItem> {
    return InnertubeParser.parseLibraryItemPage(root).items;
  }

  static parseLibraryItemPage(root: Object | null | undefined): LibraryItemPage {
    const outMap: Map<string, ShelfItem> = new Map<string, ShelfItem>();
    const twoRows = InnertubeParser.collectRenderers(root, 'musicTwoRowItemRenderer');
    for (let i = 0; i < twoRows.length; i++) {
      const item = InnertubeParser.parseTwoRowItem(twoRows[i]);
      if (item !== null && item.browseId !== null && !outMap.has(item.browseId)) {
        outMap.set(item.browseId, item);
      }
    }
    const respRows = InnertubeParser.collectRenderers(root, 'musicResponsiveListItemRenderer');
    for (let i = 0; i < respRows.length; i++) {
      const bItem = InnertubeParser.parseBrowseItem(respRows[i]);
      if (bItem !== null && !outMap.has(bItem.browseId)) {
        outMap.set(bItem.browseId, new ShelfItem(bItem.title, bItem.subtitle, bItem.thumbnailUrl, null, bItem.browseId));
      }
    }
    return new LibraryItemPage(Array.from(outMap.values()), InnertubeParser.continuationToken(root));
  }

  static continuationToken(root: Object | null | undefined): string | null {
    const contItems = InnertubeParser.collectRenderers(root, 'continuationItemRenderer');
    if (contItems.length > 0) {
      const endpoint = jsonObj(contItems[0], 'continuationEndpoint');
      const directCmd = jsonObj(endpoint, 'continuationCommand');
      if (directCmd !== null) {
        const t = jsonStr(directCmd, 'token');
        if (t !== null) {
          return t;
        }
      }
      const commands = jsonArr(jsonObj(endpoint, 'commandExecutorCommand'), 'commands');
      if (commands !== null) {
        for (let i = 0; i < commands.length; i++) {
          const cmd = jsonObj(commands[i], 'continuationCommand');
          const t = jsonStr(cmd, 'token');
          if (t !== null) {
            return t;
          }
        }
      }
    }
    const nextData = InnertubeParser.collectRenderers(root, 'nextContinuationData');
    if (nextData.length > 0) {
      return jsonStr(nextData[0], 'continuation');
    }
    return null;
  }

  static parseBrowseHeader(root: Object | null | undefined): BrowseHeader | null {
    let header: JsonRecord | null = null;
    for (let i = 0; i < HEADER_RENDERERS.length; i++) {
      const found = InnertubeParser.collectRenderers(root, HEADER_RENDERERS[i]);
      if (found.length > 0) {
        header = found[0];
        break;
      }
    }
    if (header === null) {
      return null;
    }
    const title = jsonRunsText(jsonObj(header, 'title'));
    if (title.trim().length === 0) {
      return null;
    }
    const subParts: Array<string> = [];
    for (let i = 0; i < HEADER_CREDIT_LINES.length; i++) {
      const lineText = jsonRunsText(jsonObj(header, HEADER_CREDIT_LINES[i])).trim();
      if (lineText.length > 0 && !subParts.includes(lineText)) {
        subParts.push(lineText);
      }
    }
    const thumbs = InnertubeParser.collectRenderers(header, 'musicThumbnailRenderer');
    const thumbUrl = thumbs.length > 0
      ? bestThumbnailUrl(jsonArr(jsonObj(thumbs[0], 'thumbnail'), 'thumbnails'))
      : null;
    return new BrowseHeader(title, subParts.join(' • '), thumbUrl);
  }

  static parseAlbumPlaylistId(root: Object | null | undefined): string | null {
    let header: JsonRecord | null = null;
    for (let i = 0; i < HEADER_RENDERERS.length; i++) {
      const found = InnertubeParser.collectRenderers(root, HEADER_RENDERERS[i]);
      if (found.length > 0) {
        header = found[0];
        break;
      }
    }
    if (header !== null) {
      const playBtns = InnertubeParser.collectRenderers(header, 'musicPlayButtonRenderer');
      for (let i = 0; i < playBtns.length; i++) {
        const pid = InnertubeParser.playlistIdFromPlayAction(playBtns[i]);
        if (pid !== null) {
          return pid;
        }
      }
      const btns = InnertubeParser.collectRenderers(header, 'buttonRenderer');
      for (let i = 0; i < btns.length; i++) {
        const pid = InnertubeParser.playlistIdFromPlayAction(btns[i]);
        if (pid !== null) {
          return pid;
        }
      }
    }
    const canonical = jsonStr(jsonObj(jsonObj(root, 'microformat'), 'microformatDataRenderer'), 'urlCanonical');
    if (canonical === null) {
      return null;
    }
    const listIdx = canonical.indexOf('list=');
    if (listIdx < 0) {
      return null;
    }
    const afterList = canonical.slice(listIdx + 5);
    const ampIdx = afterList.indexOf('&');
    const id = (ampIdx >= 0 ? afterList.slice(0, ampIdx) : afterList).trim();
    return id.length > 0 ? id : null;
  }

  static parseDescription(root: Object | null | undefined): string | null {
    const descShelves = InnertubeParser.collectRenderers(root, 'musicDescriptionShelfRenderer');
    if (descShelves.length > 0) {
      const text = jsonRunsText(jsonObj(descShelves[0], 'description')).trim();
      if (text.length > 0) {
        return text;
      }
    }
    const allHeaderNames: Array<string> = ['musicResponsiveHeaderRenderer', 'musicDetailHeaderRenderer', 'musicImmersiveHeaderRenderer'];
    for (let i = 0; i < allHeaderNames.length; i++) {
      const headers = InnertubeParser.collectRenderers(root, allHeaderNames[i]);
      if (headers.length > 0) {
        const text = jsonRunsText(jsonObj(headers[0], 'description')).trim();
        if (text.length > 0) {
          return text;
        }
      }
    }
    return null;
  }

  static parseAccount(response: Object | null | undefined): Account | null {
    const headers = InnertubeParser.collectRenderers(response, 'activeAccountHeaderRenderer');
    if (headers.length === 0) {
      return null;
    }
    const header = headers[0];
    const name = jsonRunsText(jsonObj(header, 'accountName')).trim();
    if (name.length === 0) {
      return null;
    }
    let email = jsonRunsText(jsonObj(header, 'email')).trim();
    if (email.length === 0) {
      const simple = jsonStr(jsonObj(header, 'email'), 'simpleText');
      email = simple !== null ? simple.trim() : '';
    }
    if (email.length === 0) {
      email = jsonRunsText(jsonObj(header, 'channelHandle')).trim();
    }
    const thumb = bestThumbnailUrl(jsonArr(jsonObj(header, 'accountPhoto'), 'thumbnails'));
    return new Account(name, email, thumb);
  }

  static parseAccountChannels(root: Object | null | undefined): Array<AccountChannel> {
    const items = InnertubeParser.collectRenderers(root, 'accountItem');
    const out: Array<AccountChannel> = [];
    const seenKeys: Array<string> = [];

    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      let name = jsonRunsText(jsonObj(item, 'accountName')).trim();
      if (name.length === 0) {
        const simple = jsonStr(jsonObj(item, 'accountName'), 'simpleText');
        name = simple !== null ? simple.trim() : '';
      }
      if (name.length === 0) {
        continue;
      }
      const pageId = jsonFindStringDeep(item, 'pageId');
      const dataSyncId = normalizeDataSyncId(jsonFindStringDeep(item, 'datasyncIdToken'));
      if (pageId === null && dataSyncId === null) {
        continue;
      }
      let subtitle = jsonRunsText(jsonObj(item, 'channelHandle')).trim();
      if (subtitle.length === 0) {
        const s1 = jsonStr(jsonObj(item, 'channelHandle'), 'simpleText');
        subtitle = s1 !== null ? s1.trim() : '';
      }
      if (subtitle.length === 0) {
        subtitle = jsonRunsText(jsonObj(item, 'accountByline')).trim();
      }
      if (subtitle.length === 0) {
        const s2 = jsonStr(jsonObj(item, 'accountByline'), 'simpleText');
        subtitle = s2 !== null ? s2.trim() : '';
      }
      const thumb = bestThumbnailUrl(jsonArr(jsonObj(item, 'accountPhoto'), 'thumbnails'));
      const activeOnWeb = jsonStr(item, 'isSelected') === 'true';
      const ch = new AccountChannel(name, subtitle, thumb, pageId, dataSyncId, activeOnWeb);
      if (!seenKeys.includes(ch.key)) {
        seenKeys.push(ch.key);
        out.push(ch);
      }
    }
    return out;
  }

  static parseWatchQueue(
    root: Object | null | undefined,
    preferAudio: boolean = false,
    preferVideo: boolean = false
  ): Array<Song> {
    const outMap: Map<string, Song> = new Map<string, Song>();
    const replacements: Map<string, JsonRecord> = new Map<string, JsonRecord>();
    const dropped: Array<string> = [];

    if (preferAudio || preferVideo) {
      const wrappers = InnertubeParser.collectRenderers(root, 'playlistPanelVideoWrapperRenderer');
      for (let i = 0; i < wrappers.length; i++) {
        const halves = InnertubeParser.wrapperRenderers(wrappers[i]);
        if (halves.length === 0) {
          continue;
        }
        const primary = halves[0];
        let chosen: JsonRecord | null = null;
        for (let j = 0; j < halves.length; j++) {
          const isAudio = InnertubeParser.isAudioTrackRenderer(halves[j]);
          if (preferVideo ? !isAudio : isAudio) {
            chosen = halves[j];
            break;
          }
        }
        if (chosen === null) {
          continue;
        }
        const primaryId = jsonStr(primary, 'videoId');
        if (primaryId === null) {
          continue;
        }
        replacements.set(primaryId, chosen);
        for (let j = 1; j < halves.length; j++) {
          const hid = jsonStr(halves[j], 'videoId');
          if (hid !== null && !dropped.includes(hid)) {
            dropped.push(hid);
          }
        }
      }
    }

    const panels = InnertubeParser.collectRenderers(root, 'playlistPanelVideoRenderer');
    for (let i = 0; i < panels.length; i++) {
      const found = panels[i];
      const foundId = jsonStr(found, 'videoId');
      if (foundId === null || dropped.includes(foundId)) {
        continue;
      }
      const target = replacements.get(foundId);
      const song = InnertubeParser.panelSong(target !== undefined ? target : found);
      if (song !== null) {
        outMap.set(song.videoId, song);
      }
    }
    return Array.from(outMap.values());
  }

  static parseVersionPair(root: Object | null | undefined, videoId: string, wantAudio: boolean): VersionPair | null {
    const fits = (r: JsonRecord | null): boolean => {
      if (r === null) {
        return false;
      }
      const mvt = InnertubeParser.musicVideoTypeOf(r);
      return mvt !== null ? ((mvt === MUSIC_VIDEO_TYPE_ATV) === wantAudio) : true;
    };

    const wrappers = InnertubeParser.collectRenderers(root, 'playlistPanelVideoWrapperRenderer');
    for (let i = 0; i < wrappers.length; i++) {
      const wrapper = wrappers[i];
      const primary = jsonObj(jsonObj(wrapper, 'primaryRenderer'), 'playlistPanelVideoRenderer');
      if (primary === null) {
        continue;
      }
      const rawCounterparts = jsonArr(wrapper, 'counterpart');
      const counterparts: Array<JsonRecord> = [];
      if (rawCounterparts !== null) {
        for (let j = 0; j < rawCounterparts.length; j++) {
          const cRec = asJsonRecord(rawCounterparts[j]);
          if (cRec !== null) {
            counterparts.push(cRec);
          }
        }
      }

      if (jsonStr(primary, 'videoId') === videoId) {
        for (let j = 0; j < counterparts.length; j++) {
          const cp = counterparts[j];
          const cpRenderer = jsonObj(jsonObj(cp, 'counterpartRenderer'), 'playlistPanelVideoRenderer');
          if (fits(cpRenderer)) {
            const song = InnertubeParser.panelSong(cpRenderer as JsonRecord);
            if (song !== null) {
              return new VersionPair(song.withIsVideo(!wantAudio), InnertubeParser.timeMapOf(cp));
            }
          }
        }
        continue;
      }

      for (let j = 0; j < counterparts.length; j++) {
        const cp = counterparts[j];
        const cpRenderer = jsonObj(jsonObj(cp, 'counterpartRenderer'), 'playlistPanelVideoRenderer');
        if (jsonStr(cpRenderer, 'videoId') === videoId && fits(primary)) {
          const song = InnertubeParser.panelSong(primary);
          if (song !== null) {
            const tm = InnertubeParser.timeMapOf(cp);
            return new VersionPair(song.withIsVideo(!wantAudio), tm !== null ? tm.inverted() : null);
          }
        }
      }
    }
    return null;
  }

  static parseSongMenu(root: Object | null | undefined, videoId: string): SongMenu | null {
    const panels = InnertubeParser.collectRenderers(root, 'playlistPanelVideoRenderer');
    let row: JsonRecord | null = null;
    for (let i = 0; i < panels.length; i++) {
      if (jsonStr(panels[i], 'videoId') === videoId) {
        row = panels[i];
        break;
      }
    }
    if (row === null) {
      return null;
    }

    const likeBtns = InnertubeParser.collectRenderers(row, 'likeButtonRenderer');
    const rawStatus = likeBtns.length > 0 ? jsonStr(likeBtns[0], 'likeStatus') : null;
    let likeStatus: LikeStatus | null = null;
    if (rawStatus === 'LIKE') {
      likeStatus = LikeStatus.LIKE;
    } else if (rawStatus === 'DISLIKE') {
      likeStatus = LikeStatus.DISLIKE;
    } else if (rawStatus === 'INDIFFERENT') {
      likeStatus = LikeStatus.INDIFFERENT;
    }

    const toggles = InnertubeParser.collectRenderers(row, 'toggleMenuServiceItemRenderer');
    let toggle: JsonRecord | null = null;
    for (let i = 0; i < toggles.length; i++) {
      const t = toggles[i];
      const defTok = jsonStr(jsonObj(jsonObj(t, 'defaultServiceEndpoint'), 'feedbackEndpoint'), 'feedbackToken');
      const defIcon = jsonStr(jsonObj(t, 'defaultIcon'), 'iconType');
      const togIcon = jsonStr(jsonObj(t, 'toggledIcon'), 'iconType');
      const isLib = (defIcon !== null && LIBRARY_ICONS.includes(defIcon)) ||
                    (togIcon !== null && LIBRARY_ICONS.includes(togIcon));
      if (defTok !== null && isLib) {
        toggle = t;
        break;
      }
    }

    const defaultAdds = jsonStr(jsonObj(toggle, 'defaultIcon'), 'iconType') === 'LIBRARY_ADD';
    const defaultToken = jsonStr(jsonObj(jsonObj(toggle, 'defaultServiceEndpoint'), 'feedbackEndpoint'), 'feedbackToken');
    const toggledToken = jsonStr(jsonObj(jsonObj(toggle, 'toggledServiceEndpoint'), 'feedbackEndpoint'), 'feedbackToken');

    return new SongMenu(
      likeStatus,
      toggle !== null && !defaultAdds,
      defaultAdds ? defaultToken : toggledToken,
      defaultAdds ? toggledToken : defaultToken
    );
  }

  static parseLibraryState(root: Object | null | undefined): LibraryState | null {
    const headers = InnertubeParser.collectRenderers(root, 'musicResponsiveHeaderRenderer');
    if (headers.length === 0) {
      return null;
    }
    const buttons = jsonArr(headers[0], 'buttons');
    if (buttons === null) {
      return null;
    }
    let saveBtn: JsonRecord | null = null;
    let playEndpoint: JsonRecord | null = null;

    for (let i = 0; i < buttons.length; i++) {
      const b = buttons[i];
      const toggle = jsonObj(b, 'toggleButtonRenderer');
      if (toggle !== null && InnertubeParser.isSaveToggleButton(toggle) && saveBtn === null) {
        saveBtn = toggle;
      }
      const playNav = jsonObj(jsonObj(b, 'musicPlayButtonRenderer'), 'playNavigationEndpoint');
      if (playNav !== null && playEndpoint === null) {
        playEndpoint = playNav;
      }
    }

    if (saveBtn === null || jsonStr(saveBtn, 'isDisabled') === 'true') {
      return null;
    }
    const pidFromWatchPlaylist = jsonStr(jsonObj(playEndpoint, 'watchPlaylistEndpoint'), 'playlistId');
    const pid = pidFromWatchPlaylist !== null
      ? pidFromWatchPlaylist
      : jsonStr(jsonObj(playEndpoint, 'watchEndpoint'), 'playlistId');
    if (pid === null) {
      return null;
    }
    return new LibraryState(pid, jsonStr(saveBtn, 'isToggled') === 'true');
  }

  static parsePlaylistOwned(root: Object | null | undefined): boolean | null {
    if (InnertubeParser.collectRenderers(root, 'musicEditablePlaylistDetailHeaderRenderer').length > 0) {
      return true;
    }
    const headers = InnertubeParser.collectRenderers(root, 'musicResponsiveHeaderRenderer');
    if (headers.length === 0) {
      return null;
    }
    const header = headers[0];
    const navItems = InnertubeParser.collectRenderers(header, 'menuNavigationItemRenderer');
    for (let i = 0; i < navItems.length; i++) {
      const iconType = jsonStr(jsonObj(navItems[i], 'icon'), 'iconType');
      if (iconType !== null && OWNER_ICONS.includes(iconType)) {
        return true;
      }
    }
    const buttons = jsonArr(header, 'buttons');
    if (buttons !== null) {
      for (let i = 0; i < buttons.length; i++) {
        if (InnertubeParser.isSaveToggleButton(jsonObj(buttons[i], 'toggleButtonRenderer'))) {
          return false;
        }
      }
    }
    return true;
  }

  static parseUserPlaylists(root: Object | null | undefined): Array<UserPlaylist> {
    const items = InnertubeParser.parseLibraryItems(root);
    const out: Array<UserPlaylist> = [];
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const browseId = item.browseId;
      if (browseId === null || !browseId.startsWith('VL')) {
        continue;
      }
      let blocked = false;
      for (let j = 0; j < NOT_EDITABLE_PREFIXES.length; j++) {
        if (browseId.startsWith(`VL${NOT_EDITABLE_PREFIXES[j]}`)) {
          blocked = true;
          break;
        }
      }
      if (!blocked) {
        out.push(new UserPlaylist(browseId.slice(2), item.title, item.subtitle, item.thumbnailUrl));
      }
    }
    return out;
  }

  static artistFromSubtitle(subtitle: string): string {
    const parts = subtitle.split(' • ');
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i].trim();
      if (p.length === 0) {
        continue;
      }
      if (!TYPE_WORDS.includes(p.toLowerCase()) && !TALLY_REGEX.test(p) && !DURATION_REGEX.test(p)) {
        return p;
      }
    }
    return subtitle;
  }

  /** Trích xuất browseId của tab Lyrics từ phản hồi `/next` của YouTube Music. */
  static extractLyricsBrowseId(nextResponse: Object | null | undefined): string | null {
    const tabs = InnertubeParser.collectRenderers(nextResponse, 'tabRenderer');
    for (let i = 0; i < tabs.length; i++) {
      const tab = tabs[i];
      const browseEndpoint = jsonObj(jsonObj(tab, 'endpoint'), 'browseEndpoint');
      const pageType = jsonStr(
        jsonObj(jsonObj(browseEndpoint, 'browseEndpointContextSupportedConfigs'), 'browseEndpointContextMusicConfig'),
        'pageType'
      );
      const browseId = jsonStr(browseEndpoint, 'browseId');
      if (browseId !== null && (pageType === 'MUSIC_PAGE_TYPE_TRACK_LYRICS' || browseId.startsWith('MPLYt_'))) {
        return browseId;
      }
    }
    return null;
  }

  // ---- Các hàm helper nội bộ của InnertubeParser --------------------------------------------

  private static isSaveToggleButton(toggle: JsonRecord | null): boolean {
    if (toggle === null) {
      return false;
    }
    return (
      jsonStr(jsonObj(toggle, 'defaultIcon'), 'iconType') === 'BOOKMARK_BORDER' ||
      jsonStr(jsonObj(toggle, 'toggledIcon'), 'iconType') === 'BOOKMARK'
    );
  }

  private static playlistIdFromPlayAction(node: JsonRecord): string | null {
    const playNav = jsonObj(node, 'playNavigationEndpoint');
    const nav = jsonObj(node, 'navigationEndpoint');
    const endpoint = playNav !== null ? playNav : (nav !== null ? nav : node);
    const fromPlaylist = jsonStr(jsonObj(endpoint, 'watchPlaylistEndpoint'), 'playlistId');
    return fromPlaylist !== null ? fromPlaylist : jsonStr(jsonObj(endpoint, 'watchEndpoint'), 'playlistId');
  }

  private static wrapperRenderers(wrapper: JsonRecord): Array<JsonRecord> {
    const out: Array<JsonRecord> = [];
    const primary = jsonObj(jsonObj(wrapper, 'primaryRenderer'), 'playlistPanelVideoRenderer');
    if (primary !== null) {
      out.push(primary);
    }
    const counterparts = jsonArr(wrapper, 'counterpart');
    if (counterparts !== null) {
      for (let i = 0; i < counterparts.length; i++) {
        const cp = jsonObj(jsonObj(counterparts[i], 'counterpartRenderer'), 'playlistPanelVideoRenderer');
        if (cp !== null) {
          out.push(cp);
        }
      }
    }
    return out;
  }

  private static musicVideoTypeOf(renderer: JsonRecord): string | null {
    return jsonStr(
      jsonObj(
        jsonObj(
          jsonObj(jsonObj(renderer, 'navigationEndpoint'), 'watchEndpoint'),
          'watchEndpointMusicSupportedConfigs'
        ),
        'watchEndpointMusicConfig'
      ),
      'musicVideoType'
    );
  }

  private static isAudioTrackRenderer(renderer: JsonRecord): boolean {
    return InnertubeParser.musicVideoTypeOf(renderer) === MUSIC_VIDEO_TYPE_ATV;
  }

  private static panelSong(renderer: JsonRecord): Song | null {
    const videoId = jsonStr(renderer, 'videoId');
    const title = jsonRunsText(jsonObj(renderer, 'title'));
    if (videoId === null || title.trim().length === 0) {
      return null;
    }
    const bylineRuns = jsonArr(jsonObj(renderer, 'longBylineText'), 'runs');
    const bylineTexts: Array<string> = [];
    let artistParts: Array<string> = [];
    let hitBullet = false;
    if (bylineRuns !== null) {
      for (let i = 0; i < bylineRuns.length; i++) {
        const t = jsonStr(bylineRuns[i], 'text');
        const str = t !== null ? t : '';
        bylineTexts.push(str);
        if (!hitBullet) {
          if (str.includes('•')) {
            hitBullet = true;
          } else {
            artistParts.push(str);
          }
        }
      }
    }
    const artist = artistParts.join('').trim();
    const credits = InnertubeParser.creditsOf(bylineRuns !== null ? bylineRuns : []);
    const lengthText = jsonRunsText(jsonObj(renderer, 'lengthText')).trim();
    let hasViews = false;
    for (let i = 0; i < bylineTexts.length; i++) {
      if (bylineTexts[i].toLowerCase().includes('views')) {
        hasViews = true;
        break;
      }
    }

    return new Song(
      videoId,
      title,
      artist,
      bestThumbnailUrl(jsonArr(jsonObj(renderer, 'thumbnail'), 'thumbnails')),
      {
        durationText: lengthText.length > 0 ? lengthText : null,
        artistId: credits.artistId,
        artists: completeArtistCredits(artist, credits.artists),
        albumId: credits.albumId,
        albumName: credits.albumName,
        isVideo: hasViews,
        isExplicit: hasExplicitBadgeDeep(renderer),
      }
    );
  }

  private static timeMapOf(counterpart: JsonRecord): VersionTimeMap | null {
    const rawSegments = jsonArr(jsonObj(counterpart, 'segmentMap'), 'segment');
    if (rawSegments === null) {
      return null;
    }
    const segments: Array<VersionTimeSegment> = [];
    for (let i = 0; i < rawSegments.length; i++) {
      const seg = rawSegments[i];
      const fromStr = jsonStr(seg, 'primaryVideoStartTimeMilliseconds');
      const toStr = jsonStr(seg, 'counterpartVideoStartTimeMilliseconds');
      const lenStr = jsonStr(seg, 'durationMilliseconds');
      if (fromStr !== null && toStr !== null && lenStr !== null) {
        const fromVal = Number(fromStr);
        const toVal = Number(toStr);
        const lenVal = Number(lenStr);
        if (Number.isFinite(fromVal) && Number.isFinite(toVal) && Number.isFinite(lenVal) && lenVal > 0) {
          segments.push(new VersionTimeSegment(fromVal, toVal, lenVal));
        }
      }
    }
    return segments.length > 0 ? new VersionTimeMap(segments) : null;
  }

  private static parseBrowseItem(renderer: JsonRecord): BrowseItem | null {
    const endpoint = jsonObj(jsonObj(renderer, 'navigationEndpoint'), 'browseEndpoint');
    const browseId = jsonStr(endpoint, 'browseId');
    if (browseId === null) {
      return null;
    }
    const pageTypeStr = jsonStr(
      jsonObj(jsonObj(endpoint, 'browseEndpointContextSupportedConfigs'), 'browseEndpointContextMusicConfig'),
      'pageType'
    );
    const pageType = pageTypeStr !== null ? pageTypeStr : '';

    const columns = jsonArr(renderer, 'flexColumns');
    const col0 = (columns !== null && columns.length > 0) ? columns[0] : null;
    const col1 = (columns !== null && columns.length > 1) ? columns[1] : null;
    const title = jsonRunsText(jsonObj(jsonObj(col0, 'musicResponsiveListItemFlexColumnRenderer'), 'text'));
    if (title.trim().length === 0) {
      return null;
    }
    const subtitle = jsonRunsText(jsonObj(jsonObj(col1, 'musicResponsiveListItemFlexColumnRenderer'), 'text'));
    if (VIDEO_WORD_REGEX.test(title) || VIDEO_WORD_REGEX.test(subtitle)) {
      return null;
    }

    const thumb = bestThumbnailUrl(
      jsonArr(jsonObj(jsonObj(jsonObj(renderer, 'thumbnail'), 'musicThumbnailRenderer'), 'thumbnail'), 'thumbnails')
    );
    let bType = BrowseType.OTHER;
    if (pageType.includes('ALBUM')) {
      bType = BrowseType.ALBUM;
    } else if (pageType.includes('ARTIST')) {
      bType = BrowseType.ARTIST;
    } else if (pageType.includes('PLAYLIST')) {
      bType = BrowseType.PLAYLIST;
    }
    return new BrowseItem(browseId, title, subtitle, thumb, bType);
  }

  private static carouselShelf(carousel: JsonRecord): HomeShelf | null {
    const header = jsonObj(jsonObj(carousel, 'header'), 'musicCarouselShelfBasicHeaderRenderer');
    const title = jsonRunsText(jsonObj(header, 'title'));
    const strapline = jsonRunsText(jsonObj(header, 'strapline'));
    const contents = jsonArr(carousel, 'contents');
    if (contents === null) {
      return null;
    }
    const parsed: Array<ShelfItem> = [];
    for (let i = 0; i < contents.length; i++) {
      const item = contents[i];
      const twoRow = InnertubeParser.parseTwoRowItem(jsonObj(item, 'musicTwoRowItemRenderer'));
      if (twoRow !== null) {
        parsed.push(twoRow);
        continue;
      }
      const respRenderer = jsonObj(item, 'musicResponsiveListItemRenderer');
      const song = InnertubeParser.parseResponsiveListItem(respRenderer);
      if (song !== null) {
        parsed.push(new ShelfItem(song.title, song.artist, song.thumbnailUrl, song.videoId, null, song.isVideo));
        continue;
      }
      const artistRow = InnertubeParser.parseArtistRow(respRenderer);
      if (artistRow !== null) {
        parsed.push(artistRow);
      }
    }

    let items: Array<ShelfItem> = parsed;
    if (VIDEO_WORD_REGEX.test(title)) {
      items = [];
      for (let i = 0; i < parsed.length; i++) {
        if (parsed[i].videoId !== null) {
          items.push(parsed[i]);
        }
      }
    }
    if (items.length === 0) {
      return null;
    }
    const shelfTitle = title.trim().length > 0 ? title : 'For you';
    const fromList = contents.length > 0 && jsonObj(contents[0], 'musicResponsiveListItemRenderer') !== null;
    return new HomeShelf(shelfTitle, items, strapline, null, null, shelfLayoutFor(shelfTitle, items, fromList));
  }

  private static plainShelf(shelf: JsonRecord): HomeShelf | null {
    const title = jsonRunsText(jsonObj(shelf, 'title'));
    const contents = jsonArr(shelf, 'contents');
    if (contents === null) {
      return null;
    }
    const items: Array<ShelfItem> = [];
    for (let i = 0; i < contents.length; i++) {
      const song = InnertubeParser.parseResponsiveListItem(jsonObj(contents[i], 'musicResponsiveListItemRenderer'));
      if (song !== null) {
        items.push(new ShelfItem(song.title, song.artist, song.thumbnailUrl, song.videoId, null, song.isVideo));
      }
    }
    if (items.length === 0) {
      return null;
    }
    const shelfTitle = title.trim().length > 0 ? title : 'For you';
    return new HomeShelf(shelfTitle, items, '', null, null, shelfLayoutFor(shelfTitle, items, true));
  }

  private static gridShelf(grid: JsonRecord): HomeShelf | null {
    const header = jsonObj(grid, 'header');
    const titled = jsonObj(header, 'gridHeaderRenderer');
    const title = jsonRunsText(jsonObj(titled, 'title'));
    const raw = jsonArr(grid, 'items');
    if (raw === null) {
      return null;
    }
    const items: Array<ShelfItem> = [];
    for (let i = 0; i < raw.length; i++) {
      const two = InnertubeParser.parseTwoRowItem(jsonObj(raw[i], 'musicTwoRowItemRenderer'));
      if (two !== null) {
        items.push(two);
        continue;
      }
      const song = InnertubeParser.parseResponsiveListItem(jsonObj(raw[i], 'musicResponsiveListItemRenderer'));
      if (song !== null) {
        items.push(new ShelfItem(song.title, song.artist, song.thumbnailUrl, song.videoId, null, song.isVideo));
      }
    }
    if (items.length === 0) {
      return null;
    }
    const shelfTitle = title.trim().length > 0 ? title : 'For you';
    return new HomeShelf(shelfTitle, items, '', null, null, shelfLayoutFor(shelfTitle, items, false));
  }

  private static extractCarouselMoreEndpoint(cHeader: JsonRecord | null): JsonRecord | null {
    if (cHeader === null) {
      return null;
    }
    const titleRuns = jsonArr(jsonObj(cHeader, 'title'), 'runs');
    if (titleRuns !== null) {
      for (let i = 0; i < titleRuns.length; i++) {
        const b = jsonObj(jsonObj(titleRuns[i], 'navigationEndpoint'), 'browseEndpoint');
        if (b !== null) {
          return b;
        }
      }
    }
    const btnBrowse = jsonObj(jsonObj(jsonObj(cHeader, 'moreContentButton'), 'buttonRenderer'), 'navigationEndpoint');
    if (jsonObj(btnBrowse, 'browseEndpoint') !== null) {
      return jsonObj(btnBrowse, 'browseEndpoint');
    }
    const musicMoreBrowse = jsonObj(jsonObj(jsonObj(cHeader, 'moreContentButton'), 'musicMoreContentButtonRenderer'), 'navigationEndpoint');
    if (jsonObj(musicMoreBrowse, 'browseEndpoint') !== null) {
      return jsonObj(musicMoreBrowse, 'browseEndpoint');
    }
    const endIcons = jsonArr(cHeader, 'endIcons');
    if (endIcons !== null) {
      for (let i = 0; i < endIcons.length; i++) {
        const navBtn = jsonObj(endIcons[i], 'musicNavigationButtonRenderer');
        const c1 = jsonObj(jsonObj(navBtn, 'clickCommand'), 'browseEndpoint');
        if (c1 !== null) {
          return c1;
        }
        const c2 = jsonObj(jsonObj(navBtn, 'navigationEndpoint'), 'browseEndpoint');
        if (c2 !== null) {
          return c2;
        }
      }
    }
    return jsonObj(jsonObj(cHeader, 'navigationEndpoint'), 'browseEndpoint');
  }

  private static headerWatchTarget(header: Object | null | undefined, buttonKey: string): WatchTarget | null {
    const endpoint = jsonObj(
      jsonObj(jsonObj(jsonObj(header, 'musicImmersiveHeaderRenderer'), buttonKey), 'buttonRenderer'),
      'navigationEndpoint'
    );
    const watch = jsonObj(endpoint, 'watchEndpoint');
    const playlistId = jsonStr(watch, 'playlistId');
    if (playlistId === null) {
      return null;
    }
    const rawParams = jsonStr(watch, 'params');
    let decodedParams: string | null = null;
    if (rawParams !== null) {
      try {
        decodedParams = decodeURIComponent(rawParams);
      } catch (_e) {
        decodedParams = rawParams;
      }
    }
    return new WatchTarget(playlistId, jsonStr(watch, 'videoId'), decodedParams);
  }

  private static subscriptionFromHeader(header: Object | null | undefined): SubscriptionState | null {
    const immersive = jsonObj(header, 'musicImmersiveHeaderRenderer');
    if (immersive === null) {
      return null;
    }
    const candidates: Array<JsonRecord | null> = [
      jsonObj(jsonObj(immersive, 'subscriptionButton2'), 'subscribeButtonRenderer'),
      jsonObj(jsonObj(immersive, 'subscriptionButton'), 'subscribeButtonRenderer'),
    ];
    for (let i = 0; i < candidates.length; i++) {
      const button = candidates[i];
      if (button === null) {
        continue;
      }
      const subscribed = getBooleanField(button, 'subscribed');
      if (subscribed === null) {
        continue;
      }
      let channelId = jsonStr(button, 'channelId');
      if (channelId === null) {
        const endpoints = jsonArr(button, 'serviceEndpoints');
        if (endpoints !== null) {
          for (let j = 0; j < endpoints.length; j++) {
            const chIds = jsonArr(jsonObj(endpoints[j], 'subscribeEndpoint'), 'channelIds');
            if (chIds !== null && chIds.length > 0 && typeof chIds[0] === 'string') {
              channelId = chIds[0] as string;
              break;
            }
          }
        }
      }
      if (channelId !== null) {
        return new SubscriptionState(channelId, subscribed);
      }
    }
    return null;
  }

  private static subscriberCountFromHeader(header: Object | null | undefined): string | null {
    const immersive = jsonObj(header, 'musicImmersiveHeaderRenderer');
    if (immersive === null) {
      return null;
    }
    const button2 = jsonObj(jsonObj(immersive, 'subscriptionButton2'), 'subscribeButtonRenderer');
    const button1 = jsonObj(jsonObj(immersive, 'subscriptionButton'), 'subscribeButtonRenderer');
    const c1 = jsonFirstRunText(jsonObj(button2, 'subscriberCountWithSubscribeText'));
    if (c1 !== null) {
      return c1;
    }
    const c2 = jsonFirstRunText(jsonObj(button1, 'longSubscriberCountText'));
    if (c2 !== null) {
      return c2;
    }
    return jsonFirstRunText(jsonObj(button1, 'shortSubscriberCountText'));
  }

  private static monthlyListenersFromHeader(header: Object | null | undefined): string | null {
    return jsonFirstRunText(jsonObj(jsonObj(header, 'musicImmersiveHeaderRenderer'), 'monthlyListenerCount'));
  }

  private static artistNameFromHeader(header: Object | null | undefined): string | null {
    const immersive = jsonObj(header, 'musicImmersiveHeaderRenderer');
    const visual = jsonObj(header, 'musicVisualHeaderRenderer');
    const renderer = immersive !== null ? immersive : visual;
    if (renderer === null) {
      return null;
    }
    const text = jsonRunsText(jsonObj(renderer, 'title')).trim();
    return text.length > 0 ? text : null;
  }

  private static artistThumbnailFromHeader(header: Object | null | undefined): string | null {
    if (header === null || header === undefined) {
      return null;
    }
    const immersive = jsonObj(header, 'musicImmersiveHeaderRenderer');
    const visual = jsonObj(header, 'musicVisualHeaderRenderer');
    const t1 = jsonObj(immersive, 'thumbnail');
    const t2 = jsonObj(visual, 'foregroundThumbnail');
    const t3 = jsonObj(visual, 'thumbnail');
    const chosen = t1 !== null ? t1 : (t2 !== null ? t2 : t3);
    const directThumb = jsonObj(chosen, 'musicThumbnailRenderer');
    const fallbackThumbs = InnertubeParser.collectRenderers(header, 'musicThumbnailRenderer');
    const renderer = directThumb !== null ? directThumb : (fallbackThumbs.length > 0 ? fallbackThumbs[0] : null);
    return bestThumbnailUrl(jsonArr(jsonObj(renderer, 'thumbnail'), 'thumbnails'));
  }

  private static parseResponsiveListItem(
    renderer: JsonRecord | null,
    fallback: CreditsInfo = new CreditsInfo()
  ): Song | null {
    if (renderer === null) {
      return null;
    }
    const pDataVid = jsonStr(jsonObj(renderer, 'playlistItemData'), 'videoId');
    const navVid = jsonStr(jsonObj(jsonObj(renderer, 'navigationEndpoint'), 'watchEndpoint'), 'videoId');
    const overlayVid = jsonStr(
      jsonObj(
        jsonObj(
          jsonObj(
            jsonObj(jsonObj(renderer, 'overlay'), 'musicItemThumbnailOverlayRenderer'),
            'content'
          ),
          'musicPlayButtonRenderer'
        ),
        'playNavigationEndpoint'
      ) !== null
        ? jsonObj(
            jsonObj(
              jsonObj(
                jsonObj(jsonObj(renderer, 'overlay'), 'musicItemThumbnailOverlayRenderer'),
                'content'
              ),
              'musicPlayButtonRenderer'
            ),
            'playNavigationEndpoint'
          )
        : null,
      'videoId'
    );
    const watchOverlayVid = jsonStr(
      jsonObj(
        jsonObj(
          jsonObj(
            jsonObj(
              jsonObj(jsonObj(renderer, 'overlay'), 'musicItemThumbnailOverlayRenderer'),
              'content'
            ),
            'musicPlayButtonRenderer'
          ),
          'playNavigationEndpoint'
        ),
        'watchEndpoint'
      ),
      'videoId'
    );
    let videoId = pDataVid !== null ? pDataVid : (watchOverlayVid !== null ? watchOverlayVid : overlayVid);
    if (videoId === null) {
      videoId = navVid;
    }
    if (videoId === null) {
      const columnsForId = jsonArr(renderer, 'flexColumns');
      if (columnsForId !== null) {
        for (let c = 0; c < columnsForId.length && videoId === null; c++) {
          const runs = jsonArr(jsonObj(jsonObj(columnsForId[c], 'musicResponsiveListItemFlexColumnRenderer'), 'text'), 'runs');
          if (runs === null) {
            continue;
          }
          for (let r = 0; r < runs.length; r++) {
            const fromRun = jsonStr(jsonObj(jsonObj(runs[r], 'navigationEndpoint'), 'watchEndpoint'), 'videoId');
            if (fromRun !== null) {
              videoId = fromRun;
              break;
            }
          }
        }
      }
    }
    if (videoId === null) {
      return null;
    }

    const columns = jsonArr(renderer, 'flexColumns');
    const col0 = (columns !== null && columns.length > 0) ? columns[0] : null;
    const col1 = (columns !== null && columns.length > 1) ? columns[1] : null;
    const title = jsonRunsText(jsonObj(jsonObj(col0, 'musicResponsiveListItemFlexColumnRenderer'), 'text'));
    if (title.trim().length === 0) {
      return null;
    }

    const subtitleRuns = jsonArr(jsonObj(jsonObj(col1, 'musicResponsiveListItemFlexColumnRenderer'), 'text'), 'runs');
    let subtitle = '';
    if (subtitleRuns !== null) {
      for (let i = 0; i < subtitleRuns.length; i++) {
        const rt = jsonStr(subtitleRuns[i], 'text');
        if (rt !== null) {
          subtitle += rt;
        }
      }
    }
    const rawParts = subtitle.split(' • ');
    const parts: Array<string> = [];
    for (let i = 0; i < rawParts.length; i++) {
      if (rawParts[i].trim().length > 0) {
        parts.push(rawParts[i]);
      }
    }

    let duration: string | null = null;
    if (parts.length > 0 && DURATION_REGEX.test(parts[parts.length - 1])) {
      duration = parts[parts.length - 1];
    } else {
      const fixedCols = jsonArr(renderer, 'fixedColumns');
      if (fixedCols !== null) {
        for (let i = 0; i < fixedCols.length; i++) {
          const fcText = jsonRunsText(jsonObj(jsonObj(fixedCols[i], 'musicResponsiveListItemFixedColumnRenderer'), 'text')).trim();
          if (DURATION_REGEX.test(fcText)) {
            duration = fcText;
            break;
          }
        }
      }
    }

    let rowType: string | null = null;
    for (let i = 0; i < parts.length; i++) {
      const lower = parts[i].toLowerCase();
      if (TYPE_WORDS.includes(lower)) {
        rowType = lower;
        break;
      }
    }

    let artistFromParts: string | null = null;
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      if (!DURATION_REGEX.test(p) && !TYPE_WORDS.includes(p.toLowerCase()) && !TALLY_REGEX.test(p)) {
        artistFromParts = p;
        break;
      }
    }

    const allColumnRuns: Array<Object | null | undefined> = [];
    if (columns !== null) {
      for (let i = 0; i < columns.length; i++) {
        const cRuns = jsonArr(jsonObj(jsonObj(columns[i], 'musicResponsiveListItemFlexColumnRenderer'), 'text'), 'runs');
        if (cRuns !== null) {
          for (let j = 0; j < cRuns.length; j++) {
            allColumnRuns.push(cRuns[j]);
          }
        }
      }
    }

    const credits = InnertubeParser.creditsOf(allColumnRuns);
    const creditedArtists = InnertubeParser.artistNamesFromRuns(subtitleRuns !== null ? subtitleRuns : []);
    const isEpisode = rowType === 'episode' || jsonFindStringDeep(renderer, 'musicVideoType') === 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE';
    const show = (isEpisode && subtitleRuns !== null) ? InnertubeParser.showNameFromRuns(subtitleRuns) : null;
    const thumbnails = jsonArr(
      jsonObj(jsonObj(jsonObj(renderer, 'thumbnail'), 'musicThumbnailRenderer'), 'thumbnail'),
      'thumbnails'
    );

    let resolvedArtist = 'Unknown artist';
    if (creditedArtists !== null && creditedArtists.trim().length > 0) {
      resolvedArtist = creditedArtists;
    } else if (credits.artistName !== null && credits.artistName.trim().length > 0) {
      resolvedArtist = credits.artistName;
    } else if (show !== null) {
      resolvedArtist = show;
    } else if (artistFromParts !== null) {
      resolvedArtist = artistFromParts;
    } else if (fallback.artistName !== null) {
      resolvedArtist = fallback.artistName;
    }

    const baseArtists = credits.artists.length > 0 ? credits.artists : fallback.artists;
    return new Song(
      videoId,
      title,
      resolvedArtist,
      bestThumbnailUrl(thumbnails),
      {
        durationText: duration,
        artistId: credits.artistId !== null ? credits.artistId : fallback.artistId,
        artists: completeArtistCredits(artistFromParts !== null ? artistFromParts : '', baseArtists),
        albumId: credits.albumId !== null ? credits.albumId : fallback.albumId,
        albumName: credits.albumName !== null ? credits.albumName : fallback.albumName,
        setVideoId: jsonStr(jsonObj(renderer, 'playlistItemData'), 'playlistSetVideoId'),
        isVideo: !isEpisode && (rowType === 'video' || isThumbnailNotSquare(thumbnails)),
        isExplicit: hasExplicitBadgeDeep(renderer),
        feedbackToken: InnertubeParser.extractFeedbackToken(renderer),
      }
    );
  }

  private static parseMultiRowListItem(renderer: JsonRecord | null, show: string | null): Song | null {
    if (renderer === null) {
      return null;
    }
    const tapVid = jsonStr(jsonObj(jsonObj(renderer, 'onTap'), 'watchEndpoint'), 'videoId');
    const overlayVid = jsonStr(
      jsonObj(
        jsonObj(
          jsonObj(
            jsonObj(
              jsonObj(jsonObj(renderer, 'overlay'), 'musicItemThumbnailOverlayRenderer'),
              'content'
            ),
            'musicPlayButtonRenderer'
          ),
          'playNavigationEndpoint'
        ),
        'watchEndpoint'
      ),
      'videoId'
    );
    const videoId = tapVid !== null ? tapVid : overlayVid;
    const title = jsonRunsText(jsonObj(renderer, 'title'));
    if (videoId === null || title.trim().length === 0) {
      return null;
    }
    const secondTitle = jsonRunsText(jsonObj(renderer, 'secondTitle')).trim();
    const artist = secondTitle.length > 0 ? secondTitle : (show !== null ? show : 'Unknown artist');
    const thumb = bestThumbnailUrl(
      jsonArr(jsonObj(jsonObj(jsonObj(renderer, 'thumbnail'), 'musicThumbnailRenderer'), 'thumbnail'), 'thumbnails')
    );
    const rawDuration = jsonRunsText(
      jsonObj(jsonObj(jsonObj(renderer, 'playbackProgress'), 'musicPlaybackProgressRenderer'), 'durationText')
    );
    return new Song(videoId, title, artist, thumb, {
      durationText: InnertubeParser.episodeRuntime(rawDuration),
      isExplicit: hasExplicitBadgeDeep(renderer),
    });
  }

  private static episodeRuntime(text: string): string | null {
    let seconds = 0;
    const matches = Array.from(text.matchAll(RUNTIME_PART_REGEX));
    for (let i = 0; i < matches.length; i++) {
      const m = matches[i];
      const count = Number(m[1]);
      const unitChar = m[2].toLowerCase().charAt(0);
      if (unitChar === 'h') {
        seconds += count * 3600;
      } else if (unitChar === 'm') {
        seconds += count * 60;
      } else {
        seconds += count;
      }
    }
    if (seconds === 0) {
      return null;
    }
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const secs = seconds % 60;
    const pad2 = (n: number): string => (n < 10 ? `0${n}` : String(n));
    return hours > 0 ? `${hours}:${pad2(minutes)}:${pad2(secs)}` : `${minutes}:${pad2(secs)}`;
  }

  private static showNameFromRuns(runs: Array<Object | null | undefined>): string | null {
    for (let i = 0; i < runs.length; i++) {
      const run = runs[i];
      const pageType = jsonStr(
        jsonObj(
          jsonObj(jsonObj(jsonObj(run, 'navigationEndpoint'), 'browseEndpoint'), 'browseEndpointContextSupportedConfigs'),
          'browseEndpointContextMusicConfig'
        ),
        'pageType'
      );
      if (pageType !== null && pageType.includes('PODCAST_SHOW')) {
        const t = jsonStr(run, 'text');
        if (t !== null && t.trim().length > 0) {
          return t.trim();
        }
      }
    }
    return null;
  }

  private static parseCardShelfSong(renderer: JsonRecord): Song | null {
    const videoId = jsonStr(jsonObj(jsonObj(renderer, 'onTap'), 'watchEndpoint'), 'videoId');
    const title = jsonRunsText(jsonObj(renderer, 'title'));
    if (videoId === null || title.trim().length === 0) {
      return null;
    }
    const subtitleRuns = jsonArr(jsonObj(renderer, 'subtitle'), 'runs');
    let subtitle = '';
    if (subtitleRuns !== null) {
      for (let i = 0; i < subtitleRuns.length; i++) {
        const rt = jsonStr(subtitleRuns[i], 'text');
        if (rt !== null) {
          subtitle += rt;
        }
      }
    }
    const rawParts = subtitle.split(' • ');
    const parts: Array<string> = [];
    for (let i = 0; i < rawParts.length; i++) {
      if (rawParts[i].trim().length > 0) {
        parts.push(rawParts[i]);
      }
    }
    const duration = (parts.length > 0 && DURATION_REGEX.test(parts[parts.length - 1])) ? parts[parts.length - 1] : null;
    let rowType: string | null = null;
    for (let i = 0; i < parts.length; i++) {
      const lower = parts[i].toLowerCase();
      if (TYPE_WORDS.includes(lower)) {
        rowType = lower;
        break;
      }
    }
    const credits = InnertubeParser.creditsOf(subtitleRuns !== null ? subtitleRuns : []);
    const creditedArtists = InnertubeParser.artistNamesFromRuns(subtitleRuns !== null ? subtitleRuns : []);
    let artistFromParts: string | null = null;
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      if (!DURATION_REGEX.test(p) && !TYPE_WORDS.includes(p.toLowerCase()) && !TALLY_REGEX.test(p)) {
        artistFromParts = p;
        break;
      }
    }
    const thumbnails = jsonArr(
      jsonObj(jsonObj(jsonObj(renderer, 'thumbnail'), 'musicThumbnailRenderer'), 'thumbnail'),
      'thumbnails'
    );
    const resolvedArtist = creditedArtists !== null
      ? creditedArtists
      : ((credits.artistName !== null && credits.artistName.trim().length > 0)
          ? credits.artistName
          : (artistFromParts !== null ? artistFromParts : 'Unknown artist'));

    return new Song(videoId, title, resolvedArtist, bestThumbnailUrl(thumbnails), {
      durationText: duration,
      artistId: credits.artistId,
      artists: completeArtistCredits(artistFromParts !== null ? artistFromParts : '', credits.artists),
      albumId: credits.albumId,
      albumName: credits.albumName,
      isVideo: rowType === 'video' || isThumbnailNotSquare(thumbnails),
      isExplicit: hasExplicitBadgeDeep(getRecordField(renderer, 'subtitleBadges')),
    });
  }

  private static cardShelfCredit(card: JsonRecord): CreditsInfo | null {
    const endpoint = jsonObj(jsonObj(card, 'onTap'), 'browseEndpoint');
    if (endpoint === null) {
      return null;
    }
    const pageType = jsonStr(
      jsonObj(jsonObj(endpoint, 'browseEndpointContextSupportedConfigs'), 'browseEndpointContextMusicConfig'),
      'pageType'
    );
    if (pageType === null || !pageType.includes('ARTIST')) {
      return null;
    }
    const name = jsonRunsText(jsonObj(card, 'title')).trim();
    if (name.length === 0) {
      return null;
    }
    return new CreditsInfo(jsonStr(endpoint, 'browseId'), name);
  }

  private static parseCardShelfBrowse(renderer: JsonRecord): BrowseItem | null {
    const endpoint = jsonObj(jsonObj(renderer, 'onTap'), 'browseEndpoint');
    const browseId = jsonStr(endpoint, 'browseId');
    if (browseId === null) {
      return null;
    }
    const pageTypeStr = jsonStr(
      jsonObj(jsonObj(endpoint, 'browseEndpointContextSupportedConfigs'), 'browseEndpointContextMusicConfig'),
      'pageType'
    );
    const pageType = pageTypeStr !== null ? pageTypeStr : '';
    if (pageType.includes('NON_MUSIC_AUDIO_TRACK')) {
      return null;
    }
    const title = jsonRunsText(jsonObj(renderer, 'title'));
    if (title.trim().length === 0) {
      return null;
    }
    const subtitle = jsonRunsText(jsonObj(renderer, 'subtitle'));
    if (VIDEO_WORD_REGEX.test(title) || VIDEO_WORD_REGEX.test(subtitle)) {
      return null;
    }
    const thumb = bestThumbnailUrl(
      jsonArr(jsonObj(jsonObj(jsonObj(renderer, 'thumbnail'), 'musicThumbnailRenderer'), 'thumbnail'), 'thumbnails')
    );
    let bType = BrowseType.OTHER;
    if (pageType.includes('ALBUM')) {
      bType = BrowseType.ALBUM;
    } else if (pageType.includes('ARTIST')) {
      bType = BrowseType.ARTIST;
    } else if (pageType.includes('PLAYLIST')) {
      bType = BrowseType.PLAYLIST;
    }
    return new BrowseItem(browseId, title, subtitle, thumb, bType);
  }

  private static parseArtistRow(renderer: JsonRecord | null): ShelfItem | null {
    if (renderer === null) {
      return null;
    }
    const endpoint = jsonObj(jsonObj(renderer, 'navigationEndpoint'), 'browseEndpoint');
    const pageType = jsonStr(
      jsonObj(jsonObj(endpoint, 'browseEndpointContextSupportedConfigs'), 'browseEndpointContextMusicConfig'),
      'pageType'
    );
    if (pageType === null || !pageType.includes('ARTIST')) {
      return null;
    }
    const browseId = jsonStr(endpoint, 'browseId');
    if (browseId === null) {
      return null;
    }
    const columns = jsonArr(renderer, 'flexColumns');
    const col0 = (columns !== null && columns.length > 0) ? columns[0] : null;
    const col1 = (columns !== null && columns.length > 1) ? columns[1] : null;
    const title = jsonRunsText(jsonObj(jsonObj(col0, 'musicResponsiveListItemFlexColumnRenderer'), 'text'));
    if (title.trim().length === 0) {
      return null;
    }
    const subtitle = jsonRunsText(jsonObj(jsonObj(col1, 'musicResponsiveListItemFlexColumnRenderer'), 'text'));
    const thumbnails = jsonArr(
      jsonObj(jsonObj(jsonObj(renderer, 'thumbnail'), 'musicThumbnailRenderer'), 'thumbnail'),
      'thumbnails'
    );
    return new ShelfItem(title, subtitle, bestThumbnailUrl(thumbnails), null, browseId);
  }

  private static parseTwoRowItem(renderer: JsonRecord | null): ShelfItem | null {
    if (renderer === null) {
      return null;
    }
    const title = jsonRunsText(jsonObj(renderer, 'title'));
    if (title.trim().length === 0) {
      return null;
    }
    const endpoint = jsonObj(renderer, 'navigationEndpoint');
    const browseId = jsonStr(jsonObj(endpoint, 'browseEndpoint'), 'browseId');
    const watchVid = jsonStr(jsonObj(endpoint, 'watchEndpoint'), 'videoId');
    const videoId = watchVid !== null
      ? watchVid
      : ((browseId !== null && browseId.startsWith('MPED')) ? browseId.slice(4) : null);
    const resolvedBrowseId = (browseId !== null && !browseId.startsWith('MPED')) ? browseId : null;
    const thumbnails = jsonArr(
      jsonObj(jsonObj(jsonObj(renderer, 'thumbnailRenderer'), 'musicThumbnailRenderer'), 'thumbnail'),
      'thumbnails'
    );
    const subtitle = jsonRunsText(jsonObj(renderer, 'subtitle'));
    const aspectRatio = jsonStr(renderer, 'aspectRatio');
    const isVideo = resolvedBrowseId === null && videoId !== null && (
      isThumbnailNotSquare(thumbnails) || (aspectRatio !== null && aspectRatio.includes('16_9'))
    );
    if (
      resolvedBrowseId !== null &&
      !resolvedBrowseId.startsWith('VL') &&
      !resolvedBrowseId.startsWith('PL') &&
      !resolvedBrowseId.startsWith('MPRE') &&
      !resolvedBrowseId.startsWith('UC') &&
      (VIDEO_WORD_REGEX.test(title) || VIDEO_WORD_REGEX.test(subtitle))
    ) {
      return null;
    }
    return new ShelfItem(title, subtitle, bestThumbnailUrl(thumbnails), videoId, resolvedBrowseId, isVideo);
  }

  private static creditsOf(runs: Array<Object | null | undefined>): CreditsInfo {
    let artistId: string | null = null;
    let artistName: string | null = null;
    let albumId: string | null = null;
    let albumName: string | null = null;
    const artists: Array<ArtistRef> = [];

    for (let i = 0; i < runs.length; i++) {
      const run = runs[i];
      const browse = jsonObj(jsonObj(run, 'navigationEndpoint'), 'browseEndpoint');
      const id = jsonStr(browse, 'browseId');
      if (id === null) {
        continue;
      }
      const pageType = jsonStr(
        jsonObj(jsonObj(browse, 'browseEndpointContextSupportedConfigs'), 'browseEndpointContextMusicConfig'),
        'pageType'
      );
      if (pageType === null) {
        continue;
      }
      const nameStr = jsonStr(run, 'text');
      const name = nameStr !== null ? nameStr : '';
      if (pageType.includes('ARTIST')) {
        if (name.trim().length > 0) {
          artists.push(new ArtistRef(name, id));
        }
        if (artistId === null) {
          artistId = id;
          artistName = name;
        }
      } else if (pageType.includes('ALBUM') && albumId === null) {
        albumId = id;
        albumName = name;
      }
    }
    ArtistNameIndex.record(artists);
    return new CreditsInfo(artistId, artistName, artists, albumId, albumName);
  }

  private static artistNamesFromRuns(runs: Array<Object | null | undefined>): string | null {
    const groups: Array<Array<Object | null | undefined>> = [[]];
    for (let i = 0; i < runs.length; i++) {
      const r = runs[i];
      const t = jsonStr(r, 'text');
      if (t !== null && t.trim() === '•') {
        groups.push([]);
      } else {
        groups[groups.length - 1].push(r);
      }
    }
    let artistGroup: Array<Object | null | undefined> | null = null;
    for (let i = 0; i < groups.length; i++) {
      const grp = groups[i];
      for (let j = 0; j < grp.length; j++) {
        const pt = jsonStr(
          jsonObj(
            jsonObj(jsonObj(jsonObj(grp[j], 'navigationEndpoint'), 'browseEndpoint'), 'browseEndpointContextSupportedConfigs'),
            'browseEndpointContextMusicConfig'
          ),
          'pageType'
        );
        if (pt !== null && pt.includes('ARTIST')) {
          artistGroup = grp;
          break;
        }
      }
      if (artistGroup !== null) {
        break;
      }
    }
    if (artistGroup === null) {
      return null;
    }
    const names: Array<string> = [];
    for (let index = 0; index < artistGroup.length; index++) {
      if (index % 2 !== 0) {
        continue;
      }
      const t = jsonStr(artistGroup[index], 'text');
      if (t !== null && t.trim().length > 0 && !names.includes(t.trim())) {
        names.push(t.trim());
      }
    }
    return names.length > 0 ? names.join(', ') : null;
  }

  private static pageCredit(root: Object | null | undefined): CreditsInfo {
    let header: JsonRecord | null = null;
    for (let i = 0; i < HEADER_RENDERERS.length; i++) {
      const found = InnertubeParser.collectRenderers(root, HEADER_RENDERERS[i]);
      if (found.length > 0) {
        header = found[0];
        break;
      }
    }
    if (header === null) {
      return new CreditsInfo();
    }
    const lineRunLists: Array<Array<Object | null | undefined>> = [];
    const parts: Array<string> = [];
    const flattenedRuns: Array<Object | null | undefined> = [];

    for (let i = 0; i < HEADER_CREDIT_LINES.length; i++) {
      const runs = jsonArr(jsonObj(header, HEADER_CREDIT_LINES[i]), 'runs');
      const list = runs !== null ? runs : [];
      lineRunLists.push(list);
      let lineStr = '';
      for (let j = 0; j < list.length; j++) {
        flattenedRuns.push(list[j]);
        const rt = jsonStr(list[j], 'text');
        if (rt !== null) {
          lineStr += rt;
        }
      }
      const splitSegments = lineStr.split(/\s*[•·]\s*/);
      for (let j = 0; j < splitSegments.length; j++) {
        const s = splitSegments[j].trim();
        if (s.length > 0) {
          parts.push(s);
        }
      }
    }

    let isRelease = false;
    for (let i = 0; i < parts.length; i++) {
      if (RELEASE_WORDS.includes(parts[i].toLowerCase())) {
        isRelease = true;
        break;
      }
    }
    if (!isRelease) {
      return new CreditsInfo();
    }

    const credits = InnertubeParser.creditsOf(flattenedRuns);
    for (let i = 0; i < lineRunLists.length; i++) {
      const credited = InnertubeParser.artistNamesFromRuns(lineRunLists[i]);
      if (credited !== null) {
        return new CreditsInfo(credits.artistId, credited, credits.artists, credits.albumId, credits.albumName);
      }
    }

    let fallbackName: string | null = null;
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      if (
        p.length > 0 &&
        !TYPE_WORDS.includes(p.toLowerCase()) &&
        !TALLY_REGEX.test(p) &&
        !YEAR_REGEX.test(p) &&
        !DURATION_REGEX.test(p)
      ) {
        fallbackName = p;
        break;
      }
    }
    return new CreditsInfo(credits.artistId, fallbackName, credits.artists, credits.albumId, credits.albumName);
  }

  private static extractFeedbackToken(renderer: JsonRecord): string | null {
    const items = jsonArr(jsonObj(jsonObj(renderer, 'menu'), 'menuRenderer'), 'items');
    if (items === null) {
      return null;
    }
    for (let i = 0; i < items.length; i++) {
      const service = jsonObj(items[i], 'menuServiceItemRenderer');
      if (service === null) {
        continue;
      }
      if (jsonStr(jsonObj(service, 'icon'), 'iconType') === 'DELETE') {
        const tok = jsonStr(jsonObj(jsonObj(service, 'serviceEndpoint'), 'feedbackEndpoint'), 'feedbackToken');
        if (tok !== null) {
          return tok;
        }
      }
    }
    return null;
  }
}

// ============================================================================
// 6. Innertube.kt (Client giao tiếp API YouTube Music trên HarmonyOS NEXT)
// ============================================================================

class SessionScope {
  dataSyncId: string | null;
  pageId: string | null;
  authUser: string;
  clientVersion: string | null;

  constructor(
    dataSyncId: string | null,
    pageId: string | null,
    authUser: string,
    clientVersion: string | null
  ) {
    this.dataSyncId = dataSyncId;
    this.pageId = pageId;
    this.authUser = authUser;
    this.clientVersion = clientVersion;
  }
}

export class ChannelSelection {
  pageId: string | null;
  dataSyncId: string | null;
  authUser: string | null;

  constructor(pageId: string | null, dataSyncId: string | null, authUser: string | null = null) {
    this.pageId = pageId;
    this.dataSyncId = dataSyncId;
    this.authUser = authUser;
  }
}

export class NotSignedInError extends Error {
  constructor() {
    super('Sign in to YouTube Music to do that');
  }
}

const VISITOR_DATA_REGEX: RegExp = /^Cg[A-Za-z0-9_%-]{40,}$/;
const CONFIG_LOGGED_IN_REGEX: RegExp = /"LOGGED_IN"\s*:\s*(true|false)/;
const CONFIG_DATASYNC_ID_REGEX: RegExp = /"DATASYNC_ID"\s*:\s*"([^"]+)"/;
const CONFIG_PAGE_ID_REGEX: RegExp = /"DELEGATED_SESSION_ID"\s*:\s*"([^"]+)"/;
const CONFIG_SESSION_INDEX_REGEX: RegExp = /"SESSION_INDEX"\s*:\s*"?(\d+)/;
const CONFIG_VISITOR_DATA_REGEX: RegExp = /"VISITOR_DATA"\s*:\s*"([^"]+)"/;
const CONFIG_CLIENT_VERSION_REGEX: RegExp = /"INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)"/;

const SAPISID_NAMES: Array<string> = ['SAPISID', '__Secure-3PAPISID', '__Secure-1PAPISID'];
const CPN_ALPHABET: string = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';

function findVisitorDataInTree(element: Object | null | undefined): string | null {
  if (typeof element === 'string') {
    return VISITOR_DATA_REGEX.test(element) ? element : null;
  }
  const arr = asJsonArray(element);
  if (arr !== null) {
    for (let i = 0; i < arr.length; i++) {
      const found = findVisitorDataInTree(arr[i]);
      if (found !== null) {
        return found;
      }
    }
  }
  return null;
}

function delayMs(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => resolve(), ms);
  });
}

export class AudioSource {
  url: string = '';
  userAgent: string = '';
}

export class AudioResolve {
  url: string | null = null;
  detail: string = '';
  userAgent: string = '';
  sources: AudioSource[] = [];
}

export class Innertube {
  private static readonly MUSIC_BASE: string = 'https://music.youtube.com/youtubei/v1';
  private static readonly MUSIC_ORIGIN: string = 'https://music.youtube.com';
  private static readonly YOUTUBE_ORIGIN: string = 'https://www.youtube.com';
  private static readonly WEB_REMIX_VERSION: string = '1.20250101.01.00';
  private static readonly WEB_REMIX_CLIENT_ID: string = '67';
  private static readonly DEFAULT_ATR_SECONDS: number = 5;

  static appLanguage: () => string | null = (): string | null => null;

  private static _cookie: string | null = null;
  private static visitorData: string | null = null;
  private static visitorDataIsSessionBound: boolean = false;
  private static scope: SessionScope | null = null;
  private static channelOverride: ChannelSelection | null = null;

  static get cookie(): string | null {
    return Innertube._cookie;
  }

  static set cookie(value: string | null) {
    if (Innertube._cookie !== value) {
      Innertube.scope = null;
      Innertube.visitorData = null;
      Innertube.visitorDataIsSessionBound = false;
      Innertube.channelOverride = null;
    }
    Innertube._cookie = value;
  }

  static get currentLocaleTag(): string {
    const appLang = Innertube.appLanguage();
    const raw = (appLang !== null && appLang.trim().length > 0) ? appLang : 'en';
    return LocaleTags.normalizeAppTag(raw);
  }

  static get currentLanguage(): string {
    return LocaleTags.ytHl(Innertube.currentLocaleTag);
  }

  private static contentRegion: string = '';

  static setContentRegion(code: string): void {
    const next = code.length === 2 ? code.toUpperCase() : '';
    if (next !== Innertube.contentRegion) {
      Innertube.visitorData = null;
      Innertube.visitorDataIsSessionBound = false;
    }
    Innertube.contentRegion = next;
  }

  static get currentRegion(): string {
    if (Innertube.contentRegion.length === 2) {
      return Innertube.contentRegion;
    }
    return LocaleTags.ytGl(Innertube.currentLocaleTag);
  }

  private static get searchRegion(): string | null {
    return Innertube.currentRegion;
  }

  private static catalogPinned(): boolean {
    return Innertube.contentRegion.length === 2;
  }

  private static prefCookie(region: string | null): string | null {
    if (region === null || region.length !== 2) {
      return null;
    }
    return `PREF=hl=${Innertube.currentLanguage}&gl=${region}`;
  }

  private static cookieWithPref(cookie: string | null, region: string | null): string | null {
    const pref = Innertube.prefCookie(region);
    if (pref === null) {
      return cookie;
    }
    if (cookie === null || cookie.trim().length === 0) {
      return pref;
    }
    const parts = cookie.split(';');
    const next: Array<string> = [];
    let replaced = false;
    for (let i = 0; i < parts.length; i++) {
      const piece = parts[i].trim();
      if (piece.length === 0) {
        continue;
      }
      if (piece.indexOf('PREF=') === 0) {
        next.push(pref);
        replaced = true;
      } else {
        next.push(piece);
      }
    }
    if (!replaced) {
      next.push(pref);
    }
    return next.join('; ');
  }

  private static get acceptLanguageHeader(): string {
    return LocaleTags.acceptLanguage(Innertube.currentLocaleTag);
  }

  private static get webRemixVersion(): string {
    return (Innertube.scope !== null && Innertube.scope.clientVersion !== null)
      ? Innertube.scope.clientVersion
      : Innertube.WEB_REMIX_VERSION;
  }

  static selectChannel(pageId: string | null, dataSyncId: string | null, authUser: string | null = null): void {
    if (pageId === null && dataSyncId === null) {
      Innertube.channelOverride = null;
    } else {
      Innertube.channelOverride = new ChannelSelection(pageId, dataSyncId, authUser);
    }
  }

  static adoptSessionScope(
    pageId: string | null,
    dataSyncId: string | null,
    authUser: string | null,
    visitorData: string | null,
    clientVersion: string | null,
    loggedIn: boolean
  ): void {
    const version = clientVersion !== null
      ? clientVersion
      : (Innertube.scope !== null ? Innertube.scope.clientVersion : null);
    if (!loggedIn) {
      Innertube.scope = version !== null ? new SessionScope(null, null, '0', version) : null;
      return;
    }
    Innertube.scope = new SessionScope(
      (dataSyncId !== null && dataSyncId.trim().length > 0) ? dataSyncId : null,
      (pageId !== null && pageId.trim().length > 0) ? pageId : null,
      (authUser !== null && authUser.trim().length > 0) ? authUser : '0',
      version
    );
    if (visitorData !== null && visitorData.trim().length > 0) {
      Innertube.visitorData = visitorData;
      Innertube.visitorDataIsSessionBound = true;
    }
  }

  private static pageIdFor(session: SessionScope | null): string | null {
    if (Innertube.channelOverride !== null) {
      return Innertube.channelOverride.pageId;
    }
    return session !== null ? session.pageId : null;
  }

  private static dataSyncIdFor(session: SessionScope | null): string | null {
    if (Innertube.channelOverride !== null) {
      return Innertube.channelOverride.dataSyncId;
    }
    return session !== null ? session.dataSyncId : null;
  }

  private static authUserFor(session: SessionScope | null): string {
    if (Innertube.channelOverride !== null && Innertube.channelOverride.authUser !== null) {
      return Innertube.channelOverride.authUser as string;
    }
    return (session !== null) ? session.authUser : '0';
  }

  static async ensureVisitorData(refresh: boolean = false): Promise<string | null> {
    if (!refresh && Innertube.visitorData !== null) {
      return Innertube.visitorData;
    }
    try {
      const fresh = await Innertube.fetchVisitorData();
      if (fresh !== null && (refresh || !Innertube.visitorDataIsSessionBound)) {
        Innertube.visitorData = fresh;
        Innertube.visitorDataIsSessionBound = false;
      }
    } catch (_e) {
      // Ignore
    }
    return Innertube.visitorData;
  }

  private static async fetchVisitorData(): Promise<string | null> {
    const body = await Innertube.httpGetText('https://www.youtube.com/sw.js_data', {
      'User-Agent': PlayerClient.WEB_USER_AGENT,
    });
    if (body === null) {
      return null;
    }
    const nlIdx = body.indexOf('\n');
    const jsonPart = nlIdx >= 0 ? body.slice(nlIdx + 1) : body.slice(5);
    const payload = safeJsonParse(jsonPart);
    return findVisitorDataInTree(payload);
  }

  static async ensureSessionScope(): Promise<void> {
    const sessionCookie = Innertube._cookie;
    if (sessionCookie === null || Innertube.scope !== null) {
      return;
    }
    try {
      const fresh = await Innertube.fetchSessionScope(sessionCookie);
      if (fresh !== null && Innertube._cookie === sessionCookie) {
        Innertube.scope = fresh;
      }
    } catch (_e) {
      // Fail open
    }
  }

  static async refreshSessionScope(): Promise<void> {
    if (Innertube._cookie === null) {
      return;
    }
    Innertube.scope = null;
    await Innertube.ensureSessionScope();
  }

  private static async fetchSessionScope(sessionCookie: string): Promise<SessionScope | null> {
    const headers: Record<string, string> = {
      'User-Agent': PlayerClient.WEB_USER_AGENT,
      'Accept-Language': Innertube.acceptLanguageHeader,
      'Cookie': sessionCookie,
    };
    const sapisid = Innertube.sapisidFrom(sessionCookie);
    if (sapisid !== null) {
      headers['Authorization'] = Innertube.sapisidHash(sapisid);
    }
    const html = await Innertube.httpGetText(`${Innertube.MUSIC_ORIGIN}/`, headers);
    if (html === null) {
      return null;
    }

    const loggedInMatch = CONFIG_LOGGED_IN_REGEX.exec(html);
    const signedIn = loggedInMatch !== null && loggedInMatch[1] === 'true';
    const verMatch = CONFIG_CLIENT_VERSION_REGEX.exec(html);
    const clientVersion = verMatch !== null ? verMatch[1] : null;

    if (!signedIn) {
      return clientVersion !== null ? new SessionScope(null, null, '0', clientVersion) : null;
    }

    const pageMatch = CONFIG_PAGE_ID_REGEX.exec(html);
    const pageId = (pageMatch !== null && pageMatch[1].trim().length > 0) ? pageMatch[1] : null;
    const dsMatch = CONFIG_DATASYNC_ID_REGEX.exec(html);
    const dataSyncId = pageId !== null ? pageId : normalizeDataSyncId(dsMatch !== null ? dsMatch[1] : null);
    const idxMatch = CONFIG_SESSION_INDEX_REGEX.exec(html);
    const authUser = (idxMatch !== null && idxMatch[1].trim().length > 0) ? idxMatch[1] : '0';

    const visMatch = CONFIG_VISITOR_DATA_REGEX.exec(html);
    if (visMatch !== null && visMatch[1].trim().length > 0) {
      Innertube.visitorData = visMatch[1];
      Innertube.visitorDataIsSessionBound = true;
    }

    return new SessionScope(dataSyncId, pageId, authUser, clientVersion);
  }

  // ---- Public InnerTube API Methods -----------------------------------------

  static async browse(
    browseId: string,
    params: string | null = null,
    regional: boolean = false,
    country: string | null = null
  ): Promise<JsonRecord> {
    const extras: JsonRecord = { 'browseId': browseId };
    if (params !== null) {
      extras['params'] = params;
    }
    if (country !== null && country.length === 2) {
      const form: JsonRecord = {};
      const values: Array<string> = [country.toUpperCase()];
      form['selectedValues'] = values;
      extras['formData'] = form;
    }
    if (regional) {
      return Innertube.postMusicAnonymous('browse', Innertube.currentRegion, extras);
    }
    return Innertube.postMusic('browse', {}, null, extras);
  }

  static async browseContinuation(token: string): Promise<JsonRecord> {
    return Innertube.postMusic(
      'browse',
      { 'ctoken': token, 'continuation': token, 'type': 'next' },
      Innertube.currentRegion,
      { 'continuation': token }
    );
  }

  static async accountMenu(): Promise<JsonRecord> {
    return Innertube.postMusic('account/account_menu', {}, Innertube.currentRegion, {});
  }

  static async accountsList(): Promise<JsonRecord> {
    return Innertube.postMusic('account/accounts_list', {}, Innertube.currentRegion, {});
  }

  static async accountSwitcher(): Promise<JsonRecord> {
    Innertube.requireSession();
    await Innertube.ensureSessionScope();
    const session = Innertube.scope;
    const headers: Record<string, string> = {
      'User-Agent': PlayerClient.WEB_USER_AGENT,
      'Accept-Language': Innertube.acceptLanguageHeader,
      'X-Origin': Innertube.YOUTUBE_ORIGIN,
      'Referer': `${Innertube.YOUTUBE_ORIGIN}/`,
    };
    if (Innertube._cookie !== null) {
      headers['Cookie'] = Innertube._cookie as string;
      headers['X-Goog-AuthUser'] = Innertube.authUserFor(session);
      const sapisid = Innertube.sapisidFrom(Innertube._cookie as string);
      if (sapisid !== null) {
        headers['Authorization'] = Innertube.sapisidHash(sapisid, Innertube.YOUTUBE_ORIGIN);
      }
    }
    const text = await Innertube.withRetry<string>(3, async (): Promise<string> => {
      const res = await Innertube.httpGetText(`${Innertube.YOUTUBE_ORIGIN}/getAccountSwitcherEndpoint`, headers);
      if (res === null) {
        throw new Error('Failed to fetch getAccountSwitcherEndpoint');
      }
      return res;
    });
    const xssiIdx = text.indexOf(")]}'");
    const cleanBody = (xssiIdx >= 0 ? text.slice(xssiIdx + 4) : text).trim();
    const parsed = asJsonRecord(safeJsonParse(cleanBody));
    return parsed !== null ? parsed : {};
  }

  static async next(videoId: string): Promise<JsonRecord> {
    return Innertube.postMusic('next', {}, Innertube.currentRegion, {
      'videoId': videoId,
      'playlistId': `RDAMVM${videoId}`,
      'isAudioOnly': true,
    });
  }

  static async nextPlaylist(
    playlistId: string,
    videoId: string | null = null,
    params: string | null = null
  ): Promise<JsonRecord> {
    const extras: JsonRecord = {
      'playlistId': playlistId,
      'isAudioOnly': true,
    };
    if (videoId !== null) {
      extras['videoId'] = videoId;
    }
    if (params !== null) {
      extras['params'] = params;
    }
    return Innertube.postMusic('next', {}, Innertube.currentRegion, extras);
  }

  static async transcript(videoId: string): Promise<JsonRecord> {
    const idBytes = encodeUtf8(videoId);
    const protoBytes = new Uint8Array(2 + idBytes.length);
    protoBytes[0] = 10;
    protoBytes[1] = idBytes.length & 0xff;
    protoBytes.set(idBytes, 2);
    const params = encodeBase64Bytes(protoBytes);
    return Innertube.postMusic('get_transcript', {}, Innertube.currentRegion, {
      'params': params,
    });
  }

  static async search(
    query: string,
    params: string | null = null,
    anonymous: boolean = true
  ): Promise<JsonRecord> {
    const extras: JsonRecord = { 'query': query };
    if (params !== null) {
      extras['params'] = params;
    }
    if (anonymous) {
      return Innertube.postMusicAnonymous('search', Innertube.searchRegion, extras);
    }
    return Innertube.postMusic('search', {}, Innertube.searchRegion, extras);
  }

  static async searchContinuation(token: string): Promise<JsonRecord> {
    return Innertube.postMusic(
      'search',
      { 'ctoken': token, 'continuation': token, 'type': 'next' },
      Innertube.searchRegion,
      { 'continuation': token }
    );
  }

  static async searchSuggestions(input: string): Promise<JsonRecord> {
    return Innertube.postMusicAnonymous('music/get_search_suggestions', Innertube.currentRegion, {
      'input': input,
    });
  }

  static async searchTypeahead(query: string): Promise<JsonRecord> {
    return Innertube.postMusicAnonymous('search', Innertube.searchRegion, {
      'query': query,
    });
  }

  static async playbackTracking(videoId: string, signatureTimestamp: number | null): Promise<PlaybackTracking | null> {
    if (Innertube._cookie === null) {
      return null;
    }
    await Innertube.ensureSessionScope();
    const contentPlaybackContext: JsonRecord = {
      'html5Preference': 'HTML5_PREF_WANTS',
      'referer': `${Innertube.MUSIC_ORIGIN}/watch?v=${videoId}`,
    };
    if (signatureTimestamp !== null) {
      contentPlaybackContext['signatureTimestamp'] = signatureTimestamp;
    }
    const playbackContext: JsonRecord = {
      'contentPlaybackContext': contentPlaybackContext,
    };
    const response = await Innertube.postMusic('player', {}, Innertube.currentRegion, {
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
      'playbackContext': playbackContext,
    });

    const tracking = jsonObj(response, 'playbackTracking');
    if (tracking === null) {
      return null;
    }
    const playbackUrl = jsonStr(jsonObj(tracking, 'videostatsPlaybackUrl'), 'baseUrl');
    if (playbackUrl === null) {
      return null;
    }
    const watchtimeUrl = jsonStr(jsonObj(tracking, 'videostatsWatchtimeUrl'), 'baseUrl');
    const atrUrl = jsonStr(jsonObj(tracking, 'atrUrl'), 'baseUrl');
    const atrSecStr = jsonStr(jsonObj(tracking, 'atrUrl'), 'elapsedMediaTimeSeconds');
    const atrAfterSeconds = (atrSecStr !== null && !Number.isNaN(Number(atrSecStr)))
      ? Number(atrSecStr)
      : Innertube.DEFAULT_ATR_SECONDS;

    return new PlaybackTracking(playbackUrl, watchtimeUrl, atrUrl, atrAfterSeconds);
  }

  static async pingPlayback(baseUrl: string, cpn: string): Promise<number> {
    return Innertube.pingStats(baseUrl, cpn, {});
  }

  static async pingWatchtime(baseUrl: string, cpn: string, seconds: number, isFinal: boolean = false): Promise<number> {
    const secStr = String(Math.trunc(seconds));
    const extras: Record<string, string> = {
      'st': '0',
      'et': secStr,
      'cmt': secStr,
      'state': isFinal ? 'paused' : 'playing',
    };
    if (isFinal) {
      extras['final'] = '1';
    }
    return Innertube.pingStats(baseUrl, cpn, extras);
  }

  static async pingAtr(baseUrl: string, cpn: string): Promise<number> {
    if (Innertube._cookie !== null) {
      await Innertube.ensureSessionScope();
    }
    const fullUrl = urlWith(baseUrl, new UrlQuery().set("cpn", cpn));
    return Innertube.httpGetStatus(fullUrl, Innertube.buildStatsHeaders(Innertube.scope));
  }

  private static async pingStats(
    baseUrl: string,
    cpn: string,
    extras: Record<string, string>
  ): Promise<number> {
    if (Innertube._cookie !== null) {
      await Innertube.ensureSessionScope();
    }
    const params: Record<string, string | number | null | undefined> = {
      'ver': '2',
      'c': 'WEB_REMIX',
      'cver': Innertube.webRemixVersion,
      'cpn': cpn,
      'cplayer': 'UNIPLAYER',
      'cbr': 'Chrome',
      'cbrver': '141.0.0.0',
      'cos': 'Windows',
      'cosver': '10.0',
      'hl': Innertube.currentLanguage.replace(/-/g, '_'),
      'cr': Innertube.currentRegion,
    };
    const extraKeys = Object.keys(extras);
    for (let i = 0; i < extraKeys.length; i++) {
      const k = extraKeys[i];
      params[k] = extras[k];
    }
    const fullUrl = urlWith(baseUrl, params);
    return Innertube.httpGetStatus(fullUrl, Innertube.buildStatsHeaders(Innertube.scope));
  }

  private static buildStatsHeaders(session: SessionScope | null): Record<string, string> {
    const headers: Record<string, string> = {
      'X-Origin': Innertube.MUSIC_ORIGIN,
      'Origin': Innertube.MUSIC_ORIGIN,
      'Referer': `${Innertube.MUSIC_ORIGIN}/`,
      'User-Agent': PlayerClient.WEB_USER_AGENT,
    };
    if (Innertube.visitorData !== null) {
      headers['X-Goog-Visitor-Id'] = Innertube.visitorData as string;
    }
    if (Innertube._cookie !== null) {
      const c = Innertube._cookie as string;
      headers['Cookie'] = c;
      headers['X-Goog-AuthUser'] = Innertube.authUserFor(session);
      const pid = Innertube.pageIdFor(session);
      if (pid !== null) {
        headers['X-Goog-PageId'] = pid;
      }
      const sapisid = Innertube.sapisidFrom(c);
      if (sapisid !== null) {
        headers['Authorization'] = Innertube.sapisidHash(sapisid);
      }
    }
    return headers;
  }

  // ---- Write Endpoints (Thao tác tài khoản: Like, Subscribe, Playlist) -----

  private static requireSession(): void {
    if (Innertube._cookie === null) {
      throw new NotSignedInError();
    }
  }

  static async rate(videoId: string, status: LikeStatus): Promise<void> {
    Innertube.requireSession();
    let endpoint = 'like/removelike';
    if (status === LikeStatus.LIKE) {
      endpoint = 'like/like';
    } else if (status === LikeStatus.DISLIKE) {
      endpoint = 'like/dislike';
    }
    const targetObj: JsonRecord = { 'videoId': videoId };
    const response = await Innertube.postMusic(endpoint, {}, Innertube.currentRegion, {
      'target': targetObj,
    });
    const errObj = jsonObj(response, 'error');
    if (errObj !== null) {
      const msg = jsonStr(errObj, 'message');
      throw new Error(`YouTube Music refused the rating: ${msg !== null ? msg : JSON.stringify(errObj)}`);
    }
  }

  static async ratePlaylist(playlistId: string, saved: boolean): Promise<void> {
    Innertube.requireSession();
    const endpoint = saved ? 'like/like' : 'like/removelike';
    const targetObj: JsonRecord = { 'playlistId': playlistId };
    const response = await Innertube.postMusic(endpoint, {}, Innertube.currentRegion, {
      'target': targetObj,
    });
    const errObj = jsonObj(response, 'error');
    if (errObj !== null) {
      const msg = jsonStr(errObj, 'message');
      throw new Error(`YouTube Music refused the change: ${msg !== null ? msg : JSON.stringify(errObj)}`);
    }
  }

  static async setSubscribed(channelId: string, subscribed: boolean): Promise<void> {
    Innertube.requireSession();
    const endpoint = subscribed ? 'subscription/subscribe' : 'subscription/unsubscribe';
    const response = await Innertube.postMusic(endpoint, {}, Innertube.currentRegion, {
      'channelIds': [channelId],
    });
    const errObj = jsonObj(response, 'error');
    if (errObj !== null) {
      const msg = jsonStr(errObj, 'message');
      throw new Error(`YouTube Music refused the change: ${msg !== null ? msg : JSON.stringify(errObj)}`);
    }
  }

  static async sendFeedback(token: string): Promise<void> {
    Innertube.requireSession();
    await Innertube.postMusic('feedback', {}, Innertube.currentRegion, {
      'feedbackTokens': [token],
    });
  }

  static async createPlaylist(
    title: string,
    privacy: PlaylistPrivacy,
    description: string | null = null,
    videoIds: Array<string> = []
  ): Promise<string> {
    Innertube.requireSession();
    const extras: JsonRecord = {
      'title': title,
      'description': description !== null ? description : '',
      'privacyStatus': privacy,
    };
    if (videoIds.length > 0) {
      extras['videoIds'] = videoIds;
    }
    const response = await Innertube.postMusic('playlist/create', {}, Innertube.currentRegion, extras);
    const directId = jsonStr(response, 'playlistId');
    const id = directId !== null ? directId : jsonFindStringDeep(response, 'playlistId');
    if (id === null) {
      throw new Error('playlist created but no id came back');
    }
    return id;
  }

  static async deletePlaylist(playlistId: string): Promise<void> {
    Innertube.requireSession();
    const rawId = playlistId.startsWith('VL') ? playlistId.slice(2) : playlistId;
    await Innertube.postMusic('playlist/delete', {}, Innertube.currentRegion, {
      'playlistId': rawId,
    });
  }

  private static async editPlaylist(playlistId: string, actions: Array<JsonRecord>): Promise<JsonRecord> {
    Innertube.requireSession();
    const rawId = playlistId.startsWith('VL') ? playlistId.slice(2) : playlistId;
    const response = await Innertube.postMusic('browse/edit_playlist', {}, Innertube.currentRegion, {
      'playlistId': rawId,
      'actions': actions,
    });
    const status = jsonStr(response, 'status');
    if (status !== null && status !== 'STATUS_SUCCEEDED') {
      throw new Error(`YouTube Music refused the edit (${status})`);
    }
    return response;
  }

  static async addToPlaylist(playlistId: string, videoIds: Array<string>): Promise<Map<string, string>> {
    const actions: Array<JsonRecord> = [];
    for (let i = 0; i < videoIds.length; i++) {
      const act: JsonRecord = {
        'action': 'ACTION_ADD_VIDEO',
        'addedVideoId': videoIds[i],
      };
      actions.push(act);
    }
    const response = await Innertube.editPlaylist(playlistId, actions);
    const results = jsonArr(response, 'playlistEditResults');
    const map = new Map<string, string>();
    if (results !== null) {
      for (let i = 0; i < results.length; i++) {
        const added = jsonObj(results[i], 'playlistEditVideoAddedResultData');
        const vid = jsonStr(added, 'videoId');
        const setVid = jsonStr(added, 'setVideoId');
        if (vid !== null && setVid !== null) {
          map.set(vid, setVid);
        }
      }
    }
    return map;
  }

  static async removeFromPlaylist(playlistId: string, entries: Array<PlaylistMove>): Promise<void> {
    const actions: Array<JsonRecord> = [];
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      const act: JsonRecord = {
        'action': 'ACTION_REMOVE_VIDEO',
        'setVideoId': entry.setVideoId,
        'removedVideoId': entry.before !== null ? entry.before : '',
      };
      actions.push(act);
    }
    await Innertube.editPlaylist(playlistId, actions);
  }

  static async movePlaylistItems(playlistId: string, moves: Array<PlaylistMove>): Promise<void> {
    if (moves.length === 0) {
      return;
    }
    const actions: Array<JsonRecord> = [];
    for (let i = 0; i < moves.length; i++) {
      const m = moves[i];
      const act: JsonRecord = {
        'action': 'ACTION_MOVE_VIDEO_BEFORE',
        'setVideoId': m.setVideoId,
      };
      if (m.before !== null) {
        act['movedSetVideoIdSuccessor'] = m.before;
      }
      actions.push(act);
    }
    await Innertube.editPlaylist(playlistId, actions);
  }

  static async renamePlaylist(playlistId: string, title: string): Promise<void> {
    await Innertube.editPlaylist(playlistId, [
      {
        'action': 'ACTION_SET_PLAYLIST_NAME',
        'playlistName': title,
      },
    ]);
  }

  static newCpn(): string {
    let out = '';
    for (let i = 0; i < 16; i++) {
      const idx = Math.floor(Math.random() * CPN_ALPHABET.length);
      out += CPN_ALPHABET.charAt(idx);
    }
    return out;
  }

  // ---- HTTP Plumbing & SAPISIDHASH Signing ---------------------------------

  private static async withRetry<T>(attempts: number, block: () => Promise<T>): Promise<T> {
    let backoff = 500;
    for (let i = 0; i < attempts - 1; i++) {
      try {
        return await block();
      } catch (e) {
        const msg = String(e);
        if (msg.toLowerCase().includes('timeout')) {
          throw new Error(msg);
        }
      }
      await delayMs(backoff);
      backoff *= 2;
    }
    return block();
  }

  private static async postMusic(
    endpoint: string,
    query: Record<string, string>,
    region: string | null,
    bodyExtras: JsonRecord
  ): Promise<JsonRecord> {
    if (Innertube._cookie !== null) {
      await Innertube.ensureSessionScope();
    }
    const session = Innertube.scope;
    const clientVersion = Innertube.webRemixVersion;

    const queryParams: Record<string, string | number | null | undefined> = {
      'prettyPrint': 'false',
      'hl': Innertube.currentLanguage,
    };
    if (region !== null && region.length === 2) {
      queryParams['gl'] = region;
    }
    const qKeys = Object.keys(query);
    for (let i = 0; i < qKeys.length; i++) {
      const k = qKeys[i];
      queryParams[k] = query[k];
    }
    const url = urlWith(`${Innertube.MUSIC_BASE}/${endpoint}`, queryParams);

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept-Language': Innertube.acceptLanguageHeader,
      'X-Origin': Innertube.MUSIC_ORIGIN,
      'Origin': Innertube.MUSIC_ORIGIN,
      'Referer': `${Innertube.MUSIC_ORIGIN}/`,
      'X-YouTube-Client-Name': Innertube.WEB_REMIX_CLIENT_ID,
      'X-YouTube-Client-Version': clientVersion,
      'User-Agent': PlayerClient.WEB_USER_AGENT,
    };
    const signedIn = Innertube._cookie !== null;
    if (signedIn && Innertube.visitorData !== null) {
      headers['X-Goog-Visitor-Id'] = Innertube.visitorData as string;
    } else if (!signedIn && !Innertube.catalogPinned() && Innertube.visitorData !== null) {
      headers['X-Goog-Visitor-Id'] = Innertube.visitorData as string;
    }
    if (Innertube._cookie !== null) {
      const c = Innertube._cookie as string;
      headers['Cookie'] = c;
      headers['X-Goog-AuthUser'] = Innertube.authUserFor(session);
      const pid = Innertube.pageIdFor(session);
      if (pid !== null) {
        headers['X-Goog-PageId'] = pid;
      }
      const sapisid = Innertube.sapisidFrom(c);
      if (sapisid !== null) {
        headers['Authorization'] = Innertube.sapisidHash(sapisid);
      }
    } else {
      const prefOnly = Innertube.prefCookie(region);
      if (prefOnly !== null) {
        headers['Cookie'] = prefOnly;
      }
    }

    const clientObj: JsonRecord = {
      'clientName': 'WEB_REMIX',
      'clientVersion': clientVersion,
      'hl': Innertube.currentLanguage,
    };
    if (region !== null) {
      clientObj['gl'] = region;
    }
    if (signedIn && Innertube.visitorData !== null) {
      clientObj['visitorData'] = Innertube.visitorData;
    } else if (!signedIn && !Innertube.catalogPinned() && Innertube.visitorData !== null) {
      clientObj['visitorData'] = Innertube.visitorData;
    }

    const userObj: JsonRecord = {
      'lockedSafetyMode': false,
    };
    const onBehalf = Innertube.dataSyncIdFor(session);
    if (onBehalf !== null) {
      userObj['onBehalfOfUser'] = onBehalf;
    }

    const requestObj: JsonRecord = { 'useSsl': true };
    const contextObj: JsonRecord = {
      'client': clientObj,
      'user': userObj,
      'request': requestObj,
    };
    const payload: JsonRecord = {
      'context': contextObj,
    };
    const extraKeys = Object.keys(bodyExtras);
    for (let i = 0; i < extraKeys.length; i++) {
      const k = extraKeys[i];
      payload[k] = bodyExtras[k];
    }

    const response = await Innertube.withRetry<JsonRecord>(3, async (): Promise<JsonRecord> => {
      return Innertube.httpPostJson(url, headers, JSON.stringify(payload));
    });

    if (Innertube.visitorData === null) {
      const respVis = jsonStr(jsonObj(response, 'responseContext'), 'visitorData');
      if (respVis !== null) {
        Innertube.visitorData = respVis;
      }
    }
    return response;
  }

  private static async postMusicAnonymous(
    endpoint: string,
    region: string | null,
    bodyExtras: JsonRecord
  ): Promise<JsonRecord> {
    const clientVersion = Innertube.webRemixVersion;
    let query = new UrlQuery().set('prettyPrint', 'false').set('hl', Innertube.currentLanguage);
    if (region !== null && region.length === 2) {
      query = query.set('gl', region);
    }
    const url = urlWith(`${Innertube.MUSIC_BASE}/${endpoint}`, query);
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept-Language': Innertube.acceptLanguageHeader,
      'X-Origin': Innertube.MUSIC_ORIGIN,
      'Origin': Innertube.MUSIC_ORIGIN,
      'Referer': `${Innertube.MUSIC_ORIGIN}/`,
      'X-YouTube-Client-Name': Innertube.WEB_REMIX_CLIENT_ID,
      'X-YouTube-Client-Version': clientVersion,
      'User-Agent': PlayerClient.WEB_USER_AGENT,
    };
    const prefOnly = Innertube.prefCookie(region);
    if (prefOnly !== null) {
      headers['Cookie'] = prefOnly;
    }
    if (!Innertube.catalogPinned() && Innertube.visitorData !== null) {
      headers['X-Goog-Visitor-Id'] = Innertube.visitorData as string;
    }

    const clientObj: JsonRecord = {
      'clientName': 'WEB_REMIX',
      'clientVersion': clientVersion,
      'hl': Innertube.currentLanguage,
    };
    if (region !== null) {
      clientObj['gl'] = region;
    }
    if (!Innertube.catalogPinned() && Innertube.visitorData !== null) {
      clientObj['visitorData'] = Innertube.visitorData;
    }
    const userObj: JsonRecord = { 'lockedSafetyMode': false };
    const requestObj: JsonRecord = { 'useSsl': true };
    const contextObj: JsonRecord = {
      'client': clientObj,
      'user': userObj,
      'request': requestObj,
    };
    const payload: JsonRecord = {
      'context': contextObj,
    };
    const extraKeys = Object.keys(bodyExtras);
    for (let i = 0; i < extraKeys.length; i++) {
      const k = extraKeys[i];
      payload[k] = bodyExtras[k];
    }

    return Innertube.withRetry<JsonRecord>(3, async (): Promise<JsonRecord> => {
      return Innertube.httpPostJson(url, headers, JSON.stringify(payload));
    });
  }

  private static async httpPostJson(
    url: string,
    headers: Record<string, string>,
    body: string
  ): Promise<JsonRecord> {
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000,
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const failText: string = typeof response.result === 'string' ? response.result : '';
        const snippet = failText.length > 160 ? failText.substring(0, 160) : failText;
        throw new Error(`HTTP ${response.responseCode} on POST ${url} ${snippet}`);
      }
      const text: string = typeof response.result === 'string'
        ? response.result
        : JSON.stringify(response.result);
      const parsed = asJsonRecord(safeJsonParse(text));
      if (parsed === null) {
        throw new Error('Invalid JSON response from InnerTube');
      }
      return parsed;
    } finally {
      client.destroy();
    }
  }

  private static async httpGetText(url: string, headers: Record<string, string>): Promise<string | null> {
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 20000,
      });
      if (response.responseCode >= 200 && response.responseCode < 300) {
        return typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      }
      return null;
    } catch (_e) {
      return null;
    } finally {
      client.destroy();
    }
  }

  private static async httpGetStatus(url: string, headers: Record<string, string>): Promise<number> {
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 20000,
      });
      return response.responseCode;
    } finally {
      client.destroy();
    }
  }

  static sapisidFrom(cookieHeader: string): string | null {
    const jar: Map<string, string> = new Map<string, string>();
    const entries = cookieHeader.split(';');
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      const eqIdx = entry.indexOf('=');
      if (eqIdx < 0) {
        continue;
      }
      const name = entry.slice(0, eqIdx).trim();
      const val = entry.slice(eqIdx + 1).trim();
      if (name.length > 0 && val.length > 0) {
        jar.set(name, val);
      }
    }
    for (let i = 0; i < SAPISID_NAMES.length; i++) {
      const found = jar.get(SAPISID_NAMES[i]);
      if (found !== undefined) {
        return found;
      }
    }
    return null;
  }

  static sapisidHash(sapisid: string, origin: string = Innertube.MUSIC_ORIGIN): string {
    const timestamp = Math.floor(Date.now() / 1000);
    const digest = sha1Hex(`${timestamp} ${sapisid} ${origin}`);
    const token = `${timestamp}_${digest}`;
    return `SAPISIDHASH ${token} SAPISID1PHASH ${token} SAPISID3PHASH ${token}`;
  }

  /**
   * Lấy URL âm thanh phát được từ client iOS / Android VR.
   * Các client này thường trả adaptiveFormats.url trực tiếp, không cần giải chữ ký web.
   */
  static async resolveMuxedUrl(videoId: string, maxBitrate: number = 0): Promise<AudioResolve> {
    const out = new AudioResolve();
    const ua = 'com.google.android.youtube/21.03.36 (Linux; U; Android 15; US) gzip';
    const body = '{"context":{"client":{"clientName":"ANDROID","clientVersion":"21.03.36",'
      + '"clientScreen":"WATCH","platform":"MOBILE","osName":"Android","osVersion":"16",'
      + '"androidSdkVersion":36,"hl":"en","gl":"US","utcOffsetMinutes":0},'
      + '"request":{"internalExperimentFlags":[],"useSsl":true},"user":{"lockedSafetyMode":false}},'
      + '"playerRequest":{"videoId":"' + videoId + '","contentCheckOk":true,"racyCheckOk":true},'
      + '"disablePlayerResponse":false}';
    try {
      const response = await Innertube.httpPostJson(
        'https://youtubei.googleapis.com/youtubei/v1/reel/reel_item_watch?prettyPrint=false',
        {
          'Content-Type': 'application/json',
          'User-Agent': ua,
          'X-Goog-Api-Format-Version': '2'
        },
        body
      );
      const player = jsonObj(response, 'playerResponse');
      const streaming = jsonObj(player, 'streamingData');
      const formats = jsonArr(streaming, 'formats');
      const preferred = Innertube.pickProgressive(formats, maxBitrate);
      const fallback = Innertube.pickProgressive(formats, maxBitrate > 0 ? 0 : 900000);
      if (preferred === null && fallback === null) {
        out.detail = 'nourl';
        return out;
      }
      const firstUrl = preferred !== null ? preferred : fallback;
      const item = new AudioSource();
      item.url = firstUrl !== null ? firstUrl : '';
      item.userAgent = ua;
      const sources: Array<AudioSource> = [item];
      if (fallback !== null && fallback !== item.url) {
        const second = new AudioSource();
        second.url = fallback;
        second.userAgent = ua;
        sources.push(second);
      }
      out.sources = sources;
      out.url = item.url;
      out.userAgent = ua;
      return out;
    } catch (_e) {
      out.detail = 'reel';
      return out;
    }
  }

  static async resolveAudioUrl(videoId: string, maxBitrate: number = 0): Promise<AudioResolve> {
    const out = new AudioResolve();
    let sawLogin = false;
    let sawFormatsWithoutUrl = false;
    const clients: Array<PlayerClient> = [
      PlayerClient.ANDROID_VR,
      PlayerClient.IOS,
      PlayerClient.ANDROID_VR_LEGACY,
    ];
    for (let i = 0; i < clients.length; i++) {
      const found = await Innertube.audioUrlForClient(videoId, clients[i], maxBitrate);
      if (found.sources.length > 0) {
        return found;
      }
      if (found.detail === 'login') {
        sawLogin = true;
      } else if (found.detail === 'nourl') {
        sawFormatsWithoutUrl = true;
      }
    }
    if (sawFormatsWithoutUrl) {
      out.detail = 'YouTube trả danh sách chất lượng nhưng không gửi URL phát trực tiếp.';
    } else if (sawLogin) {
      out.detail = 'YouTube chặn stream và yêu cầu xác minh trình phát.';
    } else {
      out.detail = 'YouTube không trả URL phát trực tiếp cho bài này.';
    }
    return out;
  }

  private static clientNameId(client: PlayerClient): string {
    if (client.clientName === 'IOS') {
      return '5';
    }
    if (client.clientName === 'ANDROID_VR') {
      return '28';
    }
    return '1';
  }

  private static async audioUrlForClient(videoId: string, client: PlayerClient,
    maxBitrate: number): Promise<AudioResolve> {
    const clientObj: JsonRecord = {
      'clientName': client.clientName,
      'clientVersion': client.clientVersion,
      'hl': 'en',
      'gl': 'US',
    };
    if (client.clientName === 'IOS') {
      clientObj['deviceMake'] = 'Apple';
      clientObj['deviceModel'] = 'iPhone16,2';
      clientObj['osName'] = 'iOS';
      clientObj['osVersion'] = '18.3.2.22D82';
    }
    const contextObj: JsonRecord = { 'client': clientObj };
    const payload: JsonRecord = {
      'context': contextObj,
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
    };
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'User-Agent': client.userAgent,
      'X-YouTube-Client-Name': Innertube.clientNameId(client),
      'X-YouTube-Client-Version': client.clientVersion,
    };
    if (Innertube.visitorData !== null) {
      headers['X-Goog-Visitor-Id'] = Innertube.visitorData as string;
      clientObj['visitorData'] = Innertube.visitorData;
    }
    if (Innertube.cookie !== null) {
      const sessionCookie = Innertube.cookie as string;
      headers['Cookie'] = sessionCookie;
      const sapisid = Innertube.sapisidFrom(sessionCookie);
      if (sapisid !== null) {
        headers['Authorization'] = Innertube.sapisidHash(sapisid, 'https://www.youtube.com');
        headers['Origin'] = 'https://www.youtube.com';
        headers['X-Origin'] = 'https://www.youtube.com';
      }
    }
    const result = new AudioResolve();
    try {
      const response = await Innertube.httpPostJson(
        'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
        headers,
        JSON.stringify(payload)
      );
      const status = jsonStr(jsonObj(response, 'playabilityStatus'), 'status');
      if (status !== null && status !== 'OK') {
        result.detail = status === 'LOGIN_REQUIRED' ? 'login' : 'blocked';
        return result;
      }
      const streaming = jsonObj(response, 'streamingData');
      const sources = Innertube.playableSources(streaming, maxBitrate, client.userAgent);
      if (sources.length === 0) {
        result.detail = 'nourl';
        return result;
      }
      result.sources = sources;
      result.url = sources[0].url;
      result.userAgent = client.userAgent;
      return result;
    } catch (_e) {
      result.detail = 'blocked';
      return result;
    }
  }

  /** Progressive MP4 first. Harmony's player cannot play YouTube's DASH audio fragments. */
  private static playableSources(streaming: JsonRecord | null, maxBitrate: number,
    userAgent: string): AudioSource[] {
    const out: AudioSource[] = [];
    const seen: string[] = [];
    const push = (url: string | null): void => {
      if (url === null || url.length === 0) {
        return;
      }
      for (let i = 0; i < seen.length; i++) {
        if (seen[i] === url) {
          return;
        }
      }
      seen.push(url);
      const item = new AudioSource();
      item.url = url;
      item.userAgent = userAgent;
      out.push(item);
    };
    push(Innertube.pickProgressive(jsonArr(streaming, 'formats'), maxBitrate));
    push(Innertube.bestAudioUrl(jsonArr(streaming, 'adaptiveFormats'), maxBitrate));
    return out;
  }

  private static pickProgressive(list: Array<Object | null | undefined> | null, maxBitrate: number): string | null {
    if (list === null) {
      return null;
    }
    let highUrl: string | null = null;
    let highRate: number = -1;
    let fitUrl: string | null = null;
    let fitRate: number = -1;
    let lowUrl: string | null = null;
    let lowRate: number = -1;
    for (let i = 0; i < list.length; i++) {
      const format = asJsonRecord(list[i]);
      if (format === null) {
        continue;
      }
      const mime = jsonStr(format, 'mimeType');
      const url = jsonStr(format, 'url');
      if (mime === null || url === null || mime.indexOf('video/mp4') !== 0) {
        continue;
      }
      const bitrate = getNumberField(format, 'bitrate');
      const rate = bitrate !== null ? bitrate : 0;
      if (lowUrl === null || rate < lowRate) {
        lowUrl = url;
        lowRate = rate;
      }
      if (rate >= highRate) {
        highUrl = url;
        highRate = rate;
      }
      if (maxBitrate > 0 && rate <= maxBitrate && rate >= fitRate) {
        fitUrl = url;
        fitRate = rate;
      }
    }
    if (maxBitrate > 0) {
      return fitUrl !== null ? fitUrl : lowUrl;
    }
    return highUrl !== null ? highUrl : lowUrl;
  }

  private static bestAudioUrl(list: Array<Object | null | undefined> | null, maxBitrate: number): string | null {
    if (list === null) {
      return null;
    }
    let bestUrl: string | null = null;
    let bestRate: number = -1;
    let bestPref: number = -1;
    let fallbackUrl: string | null = null;
    let fallbackRate: number = -1;
    let fallbackPref: number = -1;
    for (let i = 0; i < list.length; i++) {
      const format = asJsonRecord(list[i]);
      if (format === null) {
        continue;
      }
      const mime = jsonStr(format, 'mimeType');
      const url = jsonStr(format, 'url');
      if (mime === null || url === null || !mime.startsWith('audio/')) {
        continue;
      }
      const pref = Innertube.audioPreference(mime);
      const bitrate = getNumberField(format, 'bitrate');
      const rate = bitrate !== null ? bitrate : 0;
      if (fallbackUrl === null || pref > fallbackPref || (pref === fallbackPref && rate < fallbackRate)) {
        fallbackPref = pref;
        fallbackRate = rate;
        fallbackUrl = url;
      }
      if (maxBitrate > 0 && rate > maxBitrate) {
        continue;
      }
      if (pref > bestPref || (pref === bestPref && rate >= bestRate)) {
        bestPref = pref;
        bestRate = rate;
        bestUrl = url;
      }
    }
    return bestUrl !== null ? bestUrl : fallbackUrl;
  }

  private static audioPreference(mime: string): number {
    const lower = mime.toLowerCase();
    if (lower.indexOf('audio/mp4') === 0 || lower.indexOf('audio/aac') === 0) {
      return 2;
    }
    if (lower.indexOf('audio/mpeg') === 0) {
      return 1;
    }
    return 0;
  }
}

// ---- Kết nối tự động Innertube vào YouTubeLyricsProviderBridge của LyricsProviders.ets -------

class DefaultYouTubeLyricsBridge implements YouTubeLyricsProviderBridge {
  async fetchPlainLyrics(videoId: string): Promise<string | null> {
    const nextResp = await Innertube.next(videoId);
    const lyricsBrowseId = InnertubeParser.extractLyricsBrowseId(nextResp);
    if (lyricsBrowseId === null) {
      return null;
    }
    const browseResp = await Innertube.browse(lyricsBrowseId);
    return InnertubeParser.parseDescription(browseResp);
  }

  async fetchTranscriptJson(videoId: string): Promise<Object | null> {
    return Innertube.transcript(videoId);
  }
}

registerYouTubeLyricsBridge(new DefaultYouTubeLyricsBridge());