/**
 * LyricsModel.ets
 * Chuyển đổi từ:
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LyricLine.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/SyllableRuns.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LyricGaps.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/BackgroundVocals.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LyricAlignments.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LyricsQuery.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LyricsSource.kt
 * - sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/player/LyricClock.kt
 * - web/app/src/lyrics/model.ts, sources.ts, clock.ts
 *
 * Chuẩn cú pháp: HarmonyOS NEXT ArkTS (Strict Mode - không dùng any/unknown,
 * không dùng object spread, không dùng destructuring, khai báo kiểu tường minh).
 */

export type LyricAlignment = 'start' | 'end';

/** Một âm tiết được canh thời gian riêng trong một từ: ký tự [startChar, endChar) hát từ startMs đến endMs. */
export class LyricSyllable {
  startMs: number = 0;
  endMs: number = 0;
  startChar: number = 0;
  endChar: number = 0;

  constructor(startMs: number, endMs: number, startChar: number, endChar: number) {
    this.startMs = startMs;
    this.endMs = endMs;
    this.startChar = startChar;
    this.endChar = endChar;
  }
}

/** Một từ trong dòng lyric; Apple Music tách các từ dài thành nhiều âm tiết (syllables) có timing riêng. */
export class LyricWord {
  startMs: number = 0;
  endMs: number = 0;
  text: string = '';
  syllables: Array<LyricSyllable> = [];

  constructor(startMs: number, endMs: number, text: string, syllables: Array<LyricSyllable> = []) {
    this.startMs = startMs;
    this.endMs = endMs;
    this.text = text;
    this.syllables = syllables;
  }
}

/** Tùy chọn khởi tạo thêm cho LyricLine (thay thế Partial<LyricLine> và object spread trong TS). */
export interface LyricLineExtra {
  words?: Array<LyricWord>;
  sungUntilMs?: number | null;
  background?: LyricLine | null;
  alignment?: LyricAlignment;
}

/** Một dòng lời bài hát. Nếu text rỗng ('') thì đó là đoạn nhạc dạo (instrumental gap). */
export class LyricLine {
  timeMs: number = 0;
  text: string = '';
  words: Array<LyricWord> = [];
  sungUntilMs: number | null = null;
  background: LyricLine | null = null;
  alignment: LyricAlignment = 'start';

  constructor(
    timeMs: number,
    text: string,
    words: Array<LyricWord> = [],
    sungUntilMs: number | null = null,
    background: LyricLine | null = null,
    alignment: LyricAlignment = 'start'
  ) {
    this.timeMs = timeMs;
    this.text = text;
    this.words = words;
    this.sungUntilMs = sungUntilMs;
    this.background = background;
    this.alignment = alignment;
  }
}

/** Hàm tạo nhanh LyricLine tuân thủ chuẩn ArkTS (không dùng spread). */
export function line(timeMs: number, text: string, extra?: LyricLineExtra): LyricLine {
  const words: Array<LyricWord> = (extra !== undefined && extra.words !== undefined) ? extra.words : [];
  const sungUntilMs: number | null = (extra !== undefined && extra.sungUntilMs !== undefined) ? extra.sungUntilMs : null;
  const background: LyricLine | null = (extra !== undefined && extra.background !== undefined) ? extra.background : null;
  const alignment: LyricAlignment = (extra !== undefined && extra.alignment !== undefined) ? extra.alignment : 'start';
  return new LyricLine(timeMs, text, words, sungUntilMs, background, alignment);
}

/** Tạo bản sao LyricLine với các trường cập nhật (thay cho `{ ...l, ... }` bị cấm trong ArkTS). */
export function copyLyricLine(source: LyricLine, overrides?: LyricLineExtra, newText?: string, newTimeMs?: number): LyricLine {
  const timeMs: number = newTimeMs !== undefined ? newTimeMs : source.timeMs;
  const text: string = newText !== undefined ? newText : source.text;
  const words: Array<LyricWord> = (overrides !== undefined && overrides.words !== undefined) ? overrides.words : source.words;
  const sungUntilMs: number | null = (overrides !== undefined && overrides.sungUntilMs !== undefined) ? overrides.sungUntilMs : source.sungUntilMs;
  const background: LyricLine | null = (overrides !== undefined && overrides.background !== undefined) ? overrides.background : source.background;
  const alignment: LyricAlignment = (overrides !== undefined && overrides.alignment !== undefined) ? overrides.alignment : source.alignment;
  return new LyricLine(timeMs, text, words, sungUntilMs, background, alignment);
}

/** Mốc lúc dòng bắt đầu được hát. Dòng canh cuối dùng mốc kết thúc của dòng trước. */
export function lyricCueMs(lines: Array<LyricLine>, index: number): number {
  const current = lines[index];
  if (current.words.length > 0) {
    return current.words[0].startMs;
  }
  if (current.alignment === 'end') {
    if (index === 0) {
      return 0;
    }
    const prev = lines[index - 1];
    if (prev.sungUntilMs !== null) {
      return prev.sungUntilMs;
    }
    if (prev.words.length > 0) {
      return prev.words[prev.words.length - 1].endMs;
    }
    return prev.timeMs;
  }
  return current.timeMs;
}

export function isGap(l: LyricLine): boolean {
  return l.text.length === 0;
}

export function isWordSynced(l: LyricLine): boolean {
  return l.words.length > 0;
}

export function hasKnownEnd(l: LyricLine): boolean {
  return l.words.length > 0 || l.sungUntilMs !== null;
}

/** Thời điểm kết thúc của từ cuối cùng, hoặc sungUntilMs, hoặc timeMs (tính cả giọng bè background). */
export function endMs(l: LyricLine): number {
  let lead: number = l.timeMs;
  if (l.words.length > 0) {
    lead = l.words[l.words.length - 1].endMs;
  } else if (l.sungUntilMs !== null) {
    lead = l.sungUntilMs;
  }
  const bgEnd: number = l.background !== null ? endMs(l.background) : lead;
  return Math.max(lead, bgEnd);
}

/** Chuẩn hóa danh sách âm tiết: sắp xếp theo thứ tự, nối liền phủ kín từ; trả về mảng rỗng nếu < 2 âm tiết. */
export function normalizedSyllables(parts: Array<LyricSyllable>, length: number): Array<LyricSyllable> {
  const usable: Array<LyricSyllable> = [];
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i];
    if (p.endChar > p.startChar && p.startChar < length) {
      usable.push(p);
    }
  }
  usable.sort((a: LyricSyllable, b: LyricSyllable): number => a.startChar - b.startChar);
  if (usable.length < 2) {
    return [];
  }
  const result: Array<LyricSyllable> = [];
  for (let index = 0; index < usable.length; index++) {
    const part = usable[index];
    const startChar: number = index === 0 ? 0 : part.startChar;
    const endChar: number = (index + 1 < usable.length) ? usable[index + 1].startChar : length;
    result.push(new LyricSyllable(
      part.startMs,
      Math.max(part.startMs, part.endMs),
      startChar,
      endChar
    ));
  }
  return result;
}

// ---- SyllableRuns.kt --------------------------------------------------------------------

/** Một mảnh văn bản kèm nhãn thời gian nguyên bản từ provider (chưa cắt khoảng trắng). */
export class TimedRun {
  startMs: number = 0;
  endMs: number = 0;
  raw: string = '';

  constructor(startMs: number, endMs: number, raw: string) {
    this.startMs = startMs;
    this.endMs = endMs;
    this.raw = raw;
  }
}

const UNSPACED_REGEX: RegExp = /[\u3400-\u9FFF\u3040-\u30FF\u3000-\u303F\uFF00-\uFFEF\u0E00-\u0E7F]/;

function isWhitespaceChar(c: string): boolean {
  return c.length > 0 && /\s/.test(c);
}

/**
 * Ghép các TimedRun thành các từ (LyricWord).
 * Các chữ Hán, Kana, Thái không bao giờ nối liền nhau, và một dòng không có khoảng trắng
 * sẽ không tự nối trừ khi spacingIsExplicit = true.
 */
export function wordsFromRuns(runs: Array<TimedRun>, spacingIsExplicit: boolean = false): Array<LyricWord> {
  let hasSpace: boolean = false;
  for (let i = 0; i < runs.length; i++) {
    if (/\s/.test(runs[i].raw)) {
      hasSpace = true;
      break;
    }
  }
  const glue: boolean = spacingIsExplicit || hasSpace;
  const words: Array<LyricWord> = [];
  let current: string = '';
  let parts: Array<LyricSyllable> = [];
  let start: number = 0;
  let end: number = 0;

  const flush = (): void => {
    if (current.length > 0) {
      words.push(new LyricWord(
        start,
        Math.max(start, end),
        current,
        normalizedSyllables(parts, current.length)
      ));
    }
    current = '';
    parts = [];
  };

  for (let i = 0; i < runs.length; i++) {
    const run = runs[i];
    const content = run.raw.trim();
    if (content.length === 0) {
      flush();
      continue;
    }
    const firstRawChar: string = run.raw.length > 0 ? run.raw.charAt(0) : '';
    const lastCurrentChar: string = current.length > 0 ? current.charAt(current.length - 1) : '';
    const firstContentChar: string = content.charAt(0);

    const joins: boolean =
      glue &&
      current.length > 0 &&
      !isWhitespaceChar(firstRawChar) &&
      !UNSPACED_REGEX.test(lastCurrentChar) &&
      !UNSPACED_REGEX.test(firstContentChar);

    if (!joins) {
      flush();
    }
    if (current.length === 0) {
      start = run.startMs;
      end = run.startMs;
    }
    const from: number = current.length;
    current += content;
    const runEnd: number = Math.max(run.startMs, run.endMs);
    parts.push(new LyricSyllable(run.startMs, runEnd, from, current.length));
    end = Math.max(end, runEnd);

    const lastRawChar: string = run.raw.length > 0 ? run.raw.charAt(run.raw.length - 1) : '';
    if (!glue || isWhitespaceChar(lastRawChar)) {
      flush();
    }
  }
  flush();
  return words;
}

// ---- LyricGaps.kt ---------------------------------------------------------------------

/** Khoảng nghỉ nhạc dạo tối thiểu (4 giây) để hiển thị dòng trống (instrumental break). */
export const MIN_GAP_MS: number = 4000;

/** Chèn các dòng trống (gap) vào những đoạn nhạc dạo kéo dài >= MIN_GAP_MS. */
export function withInstrumentalGaps(lines: Array<LyricLine>): Array<LyricLine> {
  if (lines.length === 0) {
    return lines;
  }
  const out: Array<LyricLine> = [];
  if (lines[0].timeMs >= MIN_GAP_MS) {
    out.push(line(0, ''));
  }
  for (let index = 0; index < lines.length; index++) {
    const l = lines[index];
    out.push(l);
    if (index + 1 < lines.length && hasKnownEnd(l)) {
      const next = lines[index + 1];
      const end = endMs(l);
      if (next.timeMs - end >= MIN_GAP_MS && end > l.timeMs) {
        out.push(line(end, ''));
      }
    }
  }
  return out;
}

// ---- BackgroundVocals.kt ----------------------------------------------------------------

function bracketStart(text: string): number | null {
  if (!text.endsWith(')')) {
    return null;
  }
  let depth: number = 0;
  for (let index = text.length - 1; index >= 0; index--) {
    const ch = text.charAt(index);
    if (ch === ')') {
      depth++;
    } else if (ch === '(') {
      depth--;
      if (depth === 0) {
        return index > 0 ? index : null;
      }
    }
  }
  return null;
}

function wordStartingAt(words: Array<LyricWord>, offset: number): number | null {
  let at: number = 0;
  for (let index = 0; index < words.length; index++) {
    if (at === offset) {
      return index;
    }
    if (at > offset) {
      return null;
    }
    at += words[index].text.length + 1;
  }
  return null;
}

/** Tách phần ngoặc đơn ở cuối dòng "(answer)" thành giọng bè (background vocal) có timing riêng. */
export function withBackgroundVocals(lines: Array<LyricLine>): Array<LyricLine> {
  const result: Array<LyricLine> = [];
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (l.background !== null || isGap(l)) {
      result.push(l);
      continue;
    }
    const open = bracketStart(l.text);
    if (open === null) {
      result.push(l);
      continue;
    }
    const lead = l.text.slice(0, open).trimEnd();
    const backing = l.text.slice(open).trim();
    if (lead.length === 0 || !/[\p{L}\p{N}]/u.test(backing)) {
      result.push(l);
      continue;
    }
    if (l.words.length === 0) {
      const bgLine = line(l.timeMs, backing, { sungUntilMs: l.sungUntilMs });
      result.push(copyLyricLine(l, { background: bgLine }, lead));
      continue;
    }
    const split = wordStartingAt(l.words, open);
    if (split === null || split <= 0) {
      result.push(l);
      continue;
    }
    const leadWords = l.words.slice(0, split);
    const backingWords = l.words.slice(split);
    const bgLine = line(backingWords[0].startMs, backing, { words: backingWords });
    result.push(copyLyricLine(l, { words: leadWords, background: bgLine }, lead));
  }
  return result;
}

// ---- LyricAlignments.kt ---------------------------------------------------------------------

const MOSTLY_RIGHT: number = 0.85;

/** Xác định bên hiển thị ('start' | 'end') cho từng dòng khi đổi giọng ca sĩ (duet); giọng nhóm giữ bên trái. */
export function lineAlignments(
  singers: Array<string | null | undefined>,
  types: Record<string, string>
): Array<LyricAlignment> {
  let left: boolean = true;
  let lastVoice: string | null = null;
  let rightward: number = 0;
  let placed: number = 0;
  const sides: Array<LyricAlignment> = [];

  for (let i = 0; i < singers.length; i++) {
    const singer = singers[i];
    if (singer === null || singer === undefined || singer.length === 0) {
      sides.push('start');
      continue;
    }
    const mappedType: string | undefined = types[singer];
    const voiceType: string = mappedType !== undefined
      ? mappedType
      : (singer === 'v1000' ? 'group' : (singer === 'v2000' ? 'other' : 'person'));
    placed += 1;
    if (voiceType === 'group') {
      sides.push('start');
      continue;
    }
    if (lastVoice === null) {
      left = voiceType !== 'other';
    } else if (singer !== lastVoice) {
      left = !left;
    }
    lastVoice = singer;
    if (!left) {
      rightward += 1;
    }
    sides.push(left ? 'start' : 'end');
  }

  if (placed === 0 || (rightward / placed) < MOSTLY_RIGHT) {
    return sides;
  }
  const flipped: Array<LyricAlignment> = [];
  for (let i = 0; i < sides.length; i++) {
    flipped.push(sides[i] === 'start' ? 'end' : 'start');
  }
  return flipped;
}

/** Kiểm tra nhãn phân đoạn kiểu Genius như "[Chorus]", "[Verse 1]". */
export function isSectionHeader(text: string): boolean {
  const t = text.trim();
  return t.startsWith('[') && t.endsWith(']') && t.length >= 3 && t.length <= 60;
}

// ---- LyricsSource.kt & LyricsQuery.kt -------------------------------------------------------

export type LyricsSourceId =
  | 'lrc-red'
  | 'bini'
  | 'better-lyrics'
  | 'better-lyrics-portato'
  | 'paxsenix'
  | 'paxsenix-spotify'
  | 'paxsenix-musixmatch'
  | 'lyrics-plus'
  | 'unison'
  | 'youtube-captions'
  | 'youtube-music'
  | 'kugou'
  | 'lrclib'
  | 'musixmatch'
  | 'genius';

export class LyricsSourceInfo {
  id: LyricsSourceId;
  label: string;
  detail: string;
  wordSynced: boolean;

  constructor(id: LyricsSourceId, label: string, detail: string, wordSynced: boolean) {
    this.id = id;
    this.label = label;
    this.detail = detail;
    this.wordSynced = wordSynced;
  }
}

export const LYRICS_SOURCES: Array<LyricsSourceInfo> = [
  new LyricsSourceInfo('lrc-red', 'lrc.red', 'Apple timings by recording, syllable by syllable', true),
  new LyricsSourceInfo('bini', 'BiniLyrics', 'The same Apple timings, matched on the recording itself', true),
  new LyricsSourceInfo('better-lyrics', 'BetterLyrics', 'Apple Music timings, word by word', true),
  new LyricsSourceInfo('better-lyrics-portato', 'BetterLyrics Portato', 'QQ Music karaoke timings through BetterLyrics', true),
  new LyricsSourceInfo('paxsenix', 'PaxSenix', 'Apple Music timings through the original keyless provider', true),
  new LyricsSourceInfo('paxsenix-spotify', 'PaxSenix: Spotify', 'Spotify lyrics with PaxSenix fallback; API key required', false),
  new LyricsSourceInfo('paxsenix-musixmatch', 'PaxSenix: Musixmatch', 'Musixmatch timings with PaxSenix fallback; API key required', true),
  new LyricsSourceInfo('lyrics-plus', 'LyricsPlus', 'Syllable by syllable, on community mirrors', true),
  new LyricsSourceInfo('unison', 'Unison', 'Contributed by listeners, so it has what nobody licensed', true),
  new LyricsSourceInfo('youtube-captions', 'YouTube captions', 'Timed captions matched to the exact playing video', false),
  new LyricsSourceInfo('youtube-music', 'YouTube Music', 'Plain lyrics from the playing video’s Lyrics tab', false),
  new LyricsSourceInfo('kugou', 'KuGou', 'Whole lines, strong outside the English catalogue', false),
  new LyricsSourceInfo('lrclib', 'LRCLIB', 'Whole lines only, and always up', false),
  new LyricsSourceInfo('musixmatch', 'Musixmatch', 'Whole lines, from the biggest lyrics database there is', false),
  new LyricsSourceInfo('genius', 'Genius', 'Plain text fallback, massive web catalogue', false),
];

export function sourceById(id: string): LyricsSourceInfo | undefined {
  for (let i = 0; i < LYRICS_SOURCES.length; i++) {
    if (LYRICS_SOURCES[i].id === id) {
      return LYRICS_SOURCES[i];
    }
  }
  return undefined;
}

/** Đồng bộ danh sách thứ tự nguồn đã lưu với danh sách nguồn của bản build hiện tại. */
export function orderedSources(saved: Array<string>): Array<LyricsSourceId> {
  const offered: Array<LyricsSourceId> = [];
  for (let i = 0; i < LYRICS_SOURCES.length; i++) {
    offered.push(LYRICS_SOURCES[i].id);
  }
  const result: Array<LyricsSourceId> = [];
  for (let i = 0; i < saved.length; i++) {
    const id = saved[i] as LyricsSourceId;
    if (offered.includes(id) && !result.includes(id)) {
      result.push(id);
    }
  }
  for (let index = 0; index < offered.length; index++) {
    const id = offered[index];
    if (result.includes(id)) {
      continue;
    }
    let before: LyricsSourceId | null = null;
    for (let j = index - 1; j >= 0; j--) {
      if (result.includes(offered[j])) {
        before = offered[j];
        break;
      }
    }
    const insertAt: number = before !== null ? result.indexOf(before) + 1 : 0;
    result.splice(insertAt, 0, id);
  }
  return result;
}

const CREDITS_PATTERNS: Array<RegExp> = [
  /\s*[([]\s*(feat|ft|featuring|with)\b[^)\]]*[)\]]/gi,
  /\s+(feat|ft|featuring)\.?\s+.*$/gi,
  /\s*[([]\s*(official\s*)?(music\s*)?(video|audio|visuali[sz]er|lyrics?\s*video|lyrics?|m\/?v|hd|hq|4k|full\s*song)\s*[)\]]/gi,
  /\s*[([]\s*official\s*[)\]]/gi,
];

/** Làm sạch tiêu đề YouTube để tìm kiếm lyrics (bỏ feat., official video/audio, giữ lại từ khóa phiên bản). */
export function forLyricsSearch(title: string): string {
  let name: string = title;
  for (let i = 0; i < CREDITS_PATTERNS.length; i++) {
    name = name.replace(CREDITS_PATTERNS[i], ' ');
  }
  const cleaned = name.replace(/\s+/g, ' ').trim().replace(/[,\-–—]+$/, '').trim();
  return cleaned.length > 0 ? cleaned : title.trim();
}

/** Loại bỏ hậu tố " - Topic" khỏi tên kênh nghệ sĩ tự động của YouTube. */
export function artistForLyricsSearch(artist: string): string {
  const parts = artist.replace(/ - Topic$/, '').split('•');
  for (let i = 0; i < parts.length; i++) {
    const piece = parts[i].trim();
    if (piece.length === 0) {
      continue;
    }
    if (/\b(views|plays|lượt xem|lượt nghe)\b/i.test(piece)) {
      continue;
    }
    if (/^\d+:\d{2}/.test(piece)) {
      continue;
    }
    return piece;
  }
  const cleaned = artist.replace(/ - Topic$/, '').trim();
  return cleaned.length > 0 ? cleaned : artist.trim();
}

// ---- LyricClock.kt (Đồng hồ nội suy vị trí chạy chữ mượt cho UI) ----------------------------

function clampNumber(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function smoothstep(fraction: number): number {
  const t = clampNumber(fraction, 0, 1);
  return t * t * (3 - 2 * t);
}

const OUTLIER_MS: number = 250;
const RATE_SLACK: number = 0.2;
const UNSETTLED_RATE_SLACK: number = 0.75;
const MAX_REJECTIONS: number = 2;
const MIN_RATE_SPAN_MS: number = 900;
const RATE_WINDOW_MS: number = 4000;
const HISTORY_LIMIT: number = 16;
const MIN_PAIR_SPAN_MS: number = 300;
const PAIR_LEARNING: number = 0.5;
const MIN_RATE: number = 0.25;
const MAX_RATE: number = 4;
const CORRECTION_MS: number = 600;
const MAX_SLEW: number = 0.25;
const MAX_SLOW: number = 0.5;
const GLIDE_FROM_MS: number = 300;
const GLIDE_MS: number = 260;
const GLIDE_MAX_MS: number = 2000;
const LOST_MS: number = 3000;

/**
 * Đồng hồ điều khiển vị trí hiển thị lời bài hát (LyricClock):
 * Chạy theo từng frame của UI và được điều hướng mượt (steered) bởi vị trí từ trình phát nhạc
 * thay vì gán cứng, giúp triệt tiêu hiện tượng giật lùi hoặc đứng khựng chữ.
 */
export class LyricClock {
  displayedMs: number;

  private lastNowMs: number = Number.NaN;
  private lastReportMs: number = Number.MIN_SAFE_INTEGER;
  private lastSampledAtMs: number = Number.NaN;
  private heldAtMs: number = Number.NEGATIVE_INFINITY;
  private lastDiscontinuity: number | null = null;
  private jumpPending: boolean = false;
  private anchorAtMs: number = Number.NaN;
  private anchorMs: number = 0;
  private rate: number = 1;
  private historyAt: Array<number> = [];
  private historyMs: Array<number> = [];
  private rateSettled: boolean = false;
  private suspectAtMs: number = Number.NaN;
  private suspectMs: number = 0;
  private rejections: number = 0;
  private glideStartMs: number = Number.NaN;
  private glideOffsetMs: number = 0;

  constructor(startMs: number) {
    this.displayedMs = startMs;
  }

  restart(): void {
    this.lastNowMs = Number.NaN;
    this.jumpPending = false;
    this.glideStartMs = Number.NaN;
    this.clearSuspect();
  }

  hold(positionMs: number, nowMs: number): void {
    this.restart();
    this.displayedMs = positionMs;
    this.heldAtMs = nowMs;
  }

  frame(nowMs: number, reportedMs: number, sampledAtMs: number, discontinuity: number): number {
    const firstOfRun = Number.isNaN(this.lastNowMs);
    if (discontinuity !== this.lastDiscontinuity) {
      if (this.lastDiscontinuity !== null && !firstOfRun) {
        this.jumpPending = true;
      }
      this.lastDiscontinuity = discontinuity;
    }
    const isNew =
      reportedMs !== this.lastReportMs ||
      (!Number.isNaN(sampledAtMs) && sampledAtMs !== this.lastSampledAtMs);
    this.lastReportMs = reportedMs;
    this.lastSampledAtMs = sampledAtMs;

    if (firstOfRun) {
      this.lastNowMs = nowMs;
      const takenAt =
        Number.isNaN(sampledAtMs) || sampledAtMs <= this.heldAtMs
          ? nowMs
          : Math.min(sampledAtMs, nowMs);
      this.anchor(takenAt, reportedMs, false);
      this.displayedMs = this.targetAt(nowMs);
      return Math.trunc(this.displayedMs);
    }

    const dt = Math.max(0, nowMs - this.lastNowMs);
    this.lastNowMs = nowMs;
    this.advance(nowMs, dt);

    if (isNew) {
      const takenAt = Number.isNaN(sampledAtMs) ? nowMs : Math.min(sampledAtMs, nowMs);
      if (takenAt >= this.anchorAtMs || this.jumpPending) {
        this.take(nowMs, takenAt, reportedMs);
      }
    }
    return Math.trunc(this.displayedMs);
  }

  private take(nowMs: number, takenAt: number, reportedMs: number): void {
    if (this.jumpPending) {
      this.jumpPending = false;
      this.clearSuspect();
      this.anchor(takenAt, reportedMs, false);
      this.jumpTo(nowMs);
      return;
    }
    const elapsed = takenAt - this.anchorAtMs;
    if (Math.abs(reportedMs - (this.anchorMs + elapsed * this.rate)) <= this.tolerance(elapsed)) {
      this.clearSuspect();
      this.anchor(takenAt, reportedMs, true);
      return;
    }
    const sinceSuspect = takenAt - this.suspectAtMs;
    const agrees =
      !Number.isNaN(this.suspectAtMs) &&
      sinceSuspect >= 0 &&
      Math.abs(reportedMs - (this.suspectMs + sinceSuspect * this.rate)) <= this.tolerance(sinceSuspect);
    this.rejections++;
    if (agrees) {
      const firstAt = this.suspectAtMs;
      const first = this.suspectMs;
      this.clearSuspect();
      this.anchor(firstAt, first, false);
      this.anchor(takenAt, reportedMs, true);
    } else if (this.rejections > MAX_REJECTIONS) {
      this.clearSuspect();
      this.anchor(takenAt, reportedMs, false);
    } else {
      this.suspectAtMs = takenAt;
      this.suspectMs = reportedMs;
    }
  }

  private tolerance(elapsedMs: number): number {
    return OUTLIER_MS + Math.abs(elapsedMs) * (this.rateSettled ? RATE_SLACK : UNSETTLED_RATE_SLACK);
  }

  private anchor(atMs: number, positionMs: number, continues: boolean = false): void {
    this.anchorAtMs = atMs;
    this.anchorMs = positionMs;
    if (!continues) {
      this.historyAt = [];
      this.historyMs = [];
    }
    if (this.historyAt.length === HISTORY_LIMIT) {
      this.historyAt.shift();
      this.historyMs.shift();
    }
    this.historyAt.push(atMs);
    this.historyMs.push(this.anchorMs);
    this.learnRate();
  }

  private learnRate(): void {
    const newest = this.historyAt.length - 1;
    if (newest < 1) {
      return;
    }
    let oldest = 0;
    while (oldest < newest && this.historyAt[newest] - this.historyAt[oldest] > RATE_WINDOW_MS) {
      oldest++;
    }
    const span = this.historyAt[newest] - this.historyAt[oldest];
    if (span >= MIN_RATE_SPAN_MS) {
      this.rate = clampNumber((this.historyMs[newest] - this.historyMs[oldest]) / span, MIN_RATE, MAX_RATE);
      this.rateSettled = true;
      return;
    }
    const pairSpan = this.historyAt[newest] - this.historyAt[newest - 1];
    if (!this.rateSettled && pairSpan >= MIN_PAIR_SPAN_MS) {
      const measured = clampNumber((this.historyMs[newest] - this.historyMs[newest - 1]) / pairSpan, MIN_RATE, MAX_RATE);
      this.rate += (measured - this.rate) * PAIR_LEARNING;
    }
  }

  private clearSuspect(): void {
    this.suspectAtMs = Number.NaN;
    this.rejections = 0;
  }

  private advance(nowMs: number, dt: number): void {
    const target = this.targetAt(nowMs);
    const step = dt * this.rate;
    const error = target - (this.displayedMs + step);
    if (!Number.isNaN(this.glideStartMs)) {
      const progress = (nowMs - this.glideStartMs) / GLIDE_MS;
      if (progress >= 1) {
        this.displayedMs = target;
        this.glideStartMs = Number.NaN;
      } else {
        this.displayedMs = target + this.glideOffsetMs * (1 - smoothstep(progress));
      }
    } else if (error <= -LOST_MS || error >= LOST_MS) {
      this.displayedMs = target;
    } else if (error >= GLIDE_FROM_MS) {
      this.startGlide(nowMs - dt, this.displayedMs - (target - step));
      this.displayedMs = target + this.glideOffsetMs * (1 - smoothstep(dt / GLIDE_MS));
    } else {
      const closing = error * (dt / (dt + CORRECTION_MS));
      this.displayedMs += step + clampNumber(closing, -MAX_SLOW * step, MAX_SLEW * step);
    }
  }

  private jumpTo(nowMs: number): void {
    const offset = this.displayedMs - this.targetAt(nowMs);
    if (Math.abs(offset) > GLIDE_MAX_MS) {
      this.displayedMs = this.targetAt(nowMs);
      this.glideStartMs = Number.NaN;
    } else {
      this.startGlide(nowMs, offset);
    }
  }

  private startGlide(startMs: number, offsetMs: number): void {
    this.glideStartMs = startMs;
    this.glideOffsetMs = offsetMs;
  }

  private targetAt(atMs: number): number {
    return this.anchorMs + (atMs - this.anchorAtMs) * this.rate;
  }
}