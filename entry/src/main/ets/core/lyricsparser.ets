/**
 * LyricsParser.ets
 * Chuyển đổi từ:
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/TtmlLyrics.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/EnhancedLrc.kt
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LrcLib.kt (parseLrc)
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/ProviderLyrics.kt (KaraokeLrc, unwrap, parseProvider)
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/LrcWriter.kt (toLrc, toEnhancedLrc)
 * - shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/lyrics/PaxSenix.kt, LyricsPlus.kt, Musixmatch.kt, KuGou.kt, Genius.kt
 * - web/app/src/lyrics/parse.ts, ttml.ts, providers.ts
 *
 * Lưu ý quan trọng cho HarmonyOS NEXT (ArkTS):
 * - Không phụ thuộc vào `DOMParser` của trình duyệt web; tích hợp sẵn bộ phân tích cú pháp cây XML/HTML
 *   thuần ArkTS (xử lý đầy đủ namespace `ttm:agent`, `ttm:role="x-bg"`, `xml:id`, nested `<span>`, text node).
 * - Tuân thủ nghiêm ngặt ArkTS Strict Mode: không `any`/`unknown`, không object spread, không destructuring,
 *   không dùng toán tử `in`.
 */

import {
  copyLyricLine,
  isGap,
  line,
  lineAlignments,
  LyricAlignment,
  LyricLine,
  LyricSyllable,
  LyricWord,
  MIN_GAP_MS,
  normalizedSyllables,
  TimedRun,
  withInstrumentalGaps,
  wordsFromRuns,
} from './lyricsmodel';

export type JsonValue = string | number | boolean | null | undefined | Object | Array<Object>;
export type JsonRecord = Record<string, Object | null | undefined>;

// ---- Các hàm tiện ích kiểm tra kiểu an toàn trong ArkTS (thay thế unknown/any) -------------

export function isJsonRecord(value: Object | null | undefined): boolean {
  return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value);
}

export function asJsonRecord(value: Object | null | undefined): JsonRecord | null {
  if (isJsonRecord(value)) {
    return value as JsonRecord;
  }
  return null;
}

export function asJsonArray(value: Object | null | undefined): Array<Object | null | undefined> | null {
  if (value !== null && value !== undefined && Array.isArray(value)) {
    return value as Array<Object | null | undefined>;
  }
  return null;
}

export function getRecordField(record: JsonRecord, key: string): Object | null | undefined {
  const keys = Object.keys(record);
  if (!keys.includes(key)) {
    return undefined;
  }
  return record[key];
}

export function getStringField(record: JsonRecord, key: string): string | null {
  const val = getRecordField(record, key);
  return typeof val === 'string' ? val : null;
}

export function getNumberField(record: JsonRecord, key: string): number | null {
  const val = getRecordField(record, key);
  return (typeof val === 'number' && Number.isFinite(val)) ? val : null;
}

export function getBooleanField(record: JsonRecord, key: string): boolean | null {
  const val = getRecordField(record, key);
  return typeof val === 'boolean' ? val : null;
}

export function safeJsonParse(raw: string | null | undefined): Object | null {
  if (raw === null || raw === undefined) {
    return null;
  }
  const trimmed = raw.trim();
  if (trimmed.length === 0) {
    return null;
  }
  try {
    return JSON.parse(trimmed) as Object;
  } catch (_e) {
    return null;
  }
}

// ---- EnhancedLrc.decodeEntities -------------------------------------------------------------

function safeFromCodePoint(entity: string, value: number): string {
  if (Number.isFinite(value) && value >= 0 && value <= 0x10ffff) {
    try {
      return String.fromCodePoint(value);
    } catch (_e) {
      return entity;
    }
  }
  return entity;
}

/** Giải mã HTML entities (&#x27;, &#39;, &amp;, &quot;, &lt;, &gt;, &nbsp;) an toàn. */
export function decodeEntities(text: string): string {
  if (!text.includes('&')) {
    return text;
  }
  return text
    .replace(/&#x([0-9a-fA-F]+);/g, (entity: string, hex: string): string => {
      return safeFromCodePoint(entity, Number.parseInt(hex, 16));
    })
    .replace(/&#(\d+);/g, (entity: string, dec: string): string => {
      return safeFromCodePoint(entity, Number(dec));
    })
    .replace(/&apos;/g, "'")
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

// ---- Bộ phân tích cây XML nhẹ thuần ArkTS cho TTML (thay thế DOMParser) --------------------

export class XmlAttribute {
  name: string;
  value: string;

  constructor(name: string, value: string) {
    this.name = name;
    this.value = value;
  }
}

export class XmlNode {
  /** 'element' | 'text' */
  nodeType: string;
  tagName: string;
  attributes: Array<XmlAttribute>;
  children: Array<XmlNode>;
  text: string;

  constructor(
    nodeType: string,
    tagName: string = '',
    attributes: Array<XmlAttribute> = [],
    children: Array<XmlNode> = [],
    text: string = ''
  ) {
    this.nodeType = nodeType;
    this.tagName = tagName;
    this.attributes = attributes;
    this.children = children;
    this.text = text;
  }

  getAttribute(attrName: string): string | null {
    for (let i = 0; i < this.attributes.length; i++) {
      if (this.attributes[i].name === attrName) {
        return this.attributes[i].value;
      }
    }
    return null;
  }

  /** Đọc thuộc tính có tiền tố namespace (ví dụ ttm:agent, ttm:role, xml:id) giống TtmlLyrics.kt. */
  qualified(attrName: string): string {
    const direct = this.getAttribute(attrName);
    if (direct !== null && direct.length > 0) {
      return direct;
    }
    const colonIdx = attrName.indexOf(':');
    const local = colonIdx >= 0 ? attrName.slice(colonIdx + 1) : attrName;
    for (let i = 0; i < this.attributes.length; i++) {
      const attr = this.attributes[i];
      const attrColon = attr.name.indexOf(':');
      const attrLocal = attrColon >= 0 ? attr.name.slice(attrColon + 1) : attr.name;
      if (attr.name === attrName || attr.name === local || attrLocal === local) {
        return attr.value;
      }
    }
    return '';
  }

  textContent(): string {
    if (this.nodeType === 'text') {
      return this.text;
    }
    let out = '';
    for (let i = 0; i < this.children.length; i++) {
      out += this.children[i].textContent();
    }
    return out;
  }

  getElementsByTagName(targetTag: string): Array<XmlNode> {
    const out: Array<XmlNode> = [];
    const targetLower = targetTag.toLowerCase();
    const walk = (node: XmlNode): void => {
      for (let i = 0; i < node.children.length; i++) {
        const child = node.children[i];
        if (child.nodeType === 'element') {
          const childLower = child.tagName.toLowerCase();
          const colonIdx = childLower.indexOf(':');
          const childLocal = colonIdx >= 0 ? childLower.slice(colonIdx + 1) : childLower;
          if (childLower === targetLower || childLocal === targetLower) {
            out.push(child);
          }
          walk(child);
        }
      }
    };
    walk(this);
    return out;
  }
}

const ATTR_REGEX: RegExp = /([A-Za-z_][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;

function parseXmlAttributes(rawAttrs: string): Array<XmlAttribute> {
  const attrs: Array<XmlAttribute> = [];
  const matches = Array.from(rawAttrs.matchAll(ATTR_REGEX));
  for (let i = 0; i < matches.length; i++) {
    const m = matches[i];
    const name = m[1];
    const val = m[2] !== undefined ? m[2] : (m[3] !== undefined ? m[3] : '');
    attrs.push(new XmlAttribute(name, decodeEntities(val)));
  }
  return attrs;
}

/** Phân tích tài liệu XML/TTML thành cây XmlNode (không cần DOMParser). */
export function parseXmlTree(xml: string): XmlNode | null {
  const root = new XmlNode('element', '#document');
  const stack: Array<XmlNode> = [root];
  const tokenRegex = /<!--[\s\S]*?-->|<!\[CDATA\[([\s\S]*?)\]\]>|<\?[\s\S]*?\?>|<!DOCTYPE[\s\S]*?>|<\/([A-Za-z_][\w:.-]*)\s*>|<([A-Za-z_][\w:.-]*)((?:\s+[^<>]*?)?)(\/?)>|([^<]+)/g;

  let match: RegExpExecArray | null = tokenRegex.exec(xml);
  while (match !== null) {
    const cdataContent = match[1];
    const closingTag = match[2];
    const openingTag = match[3];
    const rawAttributes = match[4];
    const selfClosingSlash = match[5];
    const textNodeContent = match[6];

    const currentParent = stack[stack.length - 1];

    if (cdataContent !== undefined) {
      currentParent.children.push(new XmlNode('text', '', [], [], cdataContent));
    } else if (closingTag !== undefined) {
      const closeLower = closingTag.toLowerCase();
      for (let i = stack.length - 1; i >= 1; i--) {
        if (stack[i].tagName.toLowerCase() === closeLower) {
          stack.length = i;
          break;
        }
      }
    } else if (openingTag !== undefined) {
      const attrs = parseXmlAttributes(rawAttributes !== undefined ? rawAttributes : '');
      const elem = new XmlNode('element', openingTag, attrs, [], '');
      currentParent.children.push(elem);
      if (selfClosingSlash !== '/') {
        stack.push(elem);
      }
    } else if (textNodeContent !== undefined) {
      const decoded = decodeEntities(textNodeContent);
      if (decoded.length > 0) {
        currentParent.children.push(new XmlNode('text', '', [], [], decoded));
      }
    }
    match = tokenRegex.exec(xml);
  }

  if (stack.length !== 1 || root.children.length === 0) {
    return null;
  }
  return root;
}

// ---- TTML Parser (TtmlLyrics.kt & parse.ts) ------------------------------------------------

const SKIPPED_ROLES: Array<string> = ['x-translation', 'x-roman'];
const BACKGROUND_ROLE: string = 'x-bg';

/** Chuyển đổi giá trị thời gian TTML (27.395, 1:05.20, 1:02:03.4, hoặc có hậu tố s/ms) sang mili-giây. */
export function ttmlTime(value: string | null | undefined): number | null {
  if (value === null || value === undefined) {
    return null;
  }
  const raw = value.trim();
  if (raw.length === 0) {
    return null;
  }
  if (raw.endsWith('ms')) {
    const ms = Number(raw.slice(0, -2));
    return Number.isFinite(ms) ? Math.trunc(ms) : null;
  }
  const withoutUnit = raw.replace(/s$/, '');
  const rawParts = withoutUnit.split(':');
  if (rawParts.length === 0 || rawParts.length > 3) {
    return null;
  }
  let seconds: number = 0;
  for (let i = 0; i < rawParts.length; i++) {
    const partNum = Number(rawParts[i]);
    if (!Number.isFinite(partNum)) {
      return null;
    }
    seconds = seconds * 60 + partNum;
  }
  return Math.trunc(seconds * 1000);
}

class TtmlPiece {
  /** 'text' | 'timed' */
  kind: string;
  text: string;
  start: number;
  end: number;

  constructor(kind: string, text: string, start: number = 0, end: number = 0) {
    this.kind = kind;
    this.text = text;
    this.start = start;
    this.end = end;
  }
}

class SungParagraphEntry {
  lyricLine: LyricLine;
  agent: string | null;

  constructor(lyricLine: LyricLine, agent: string | null) {
    this.lyricLine = lyricLine;
    this.agent = agent;
  }
}

function hasTimedChild(element: XmlNode): boolean {
  for (let i = 0; i < element.children.length; i++) {
    const child = element.children[i];
    if (child.nodeType === 'element') {
      const beginAttr = child.getAttribute('begin');
      if ((beginAttr !== null && beginAttr.length > 0) || hasTimedChild(child)) {
        return true;
      }
    }
  }
  return false;
}

function collectTtmlPieces(node: XmlNode, out: Array<TtmlPiece>, backing: Array<TtmlPiece>): void {
  for (let i = 0; i < node.children.length; i++) {
    const child = node.children[i];
    if (child.nodeType === 'element') {
      const role = child.qualified('ttm:role');
      if (SKIPPED_ROLES.includes(role)) {
        continue;
      }
      const sink: Array<TtmlPiece> = role === BACKGROUND_ROLE ? backing : out;
      const begin = ttmlTime(child.getAttribute('begin'));
      const end = ttmlTime(child.getAttribute('end'));
      if (begin !== null && end !== null && !hasTimedChild(child)) {
        sink.push(new TtmlPiece('timed', child.textContent(), begin, end));
      } else {
        collectTtmlPieces(child, sink, backing);
      }
    } else if (child.nodeType === 'text') {
      if (child.text.length > 0) {
        out.push(new TtmlPiece('text', child.text));
      }
    }
  }
}

function mergePiecesIntoWords(pieces: Array<TtmlPiece>): Array<LyricWord> {
  const words: Array<LyricWord> = [];
  let current: string = '';
  let syllables: Array<LyricSyllable> = [];
  let start: number = 0;
  let end: number = 0;
  let timed: boolean = false;

  const flush = (): void => {
    const text = current.trim();
    current = '';
    if (text.length > 0 && timed) {
      words.push(new LyricWord(start, end, text, normalizedSyllables(syllables, text.length)));
    }
    syllables = [];
    timed = false;
  };

  for (let i = 0; i < pieces.length; i++) {
    const piece = pieces[i];
    if (piece.kind === 'text') {
      if (piece.text.trim().length === 0) {
        flush();
      } else if (timed) {
        current += piece.text;
      }
      continue;
    }
    const trimmedPiece = piece.text.trim();
    if (trimmedPiece.length === 0) {
      continue;
    }
    if (/^\s/.test(piece.text)) {
      flush();
    }
    if (current.length === 0) {
      start = piece.start;
    }
    const from: number = current.length;
    current += trimmedPiece;
    syllables.push(new LyricSyllable(piece.start, piece.end, from, current.length));
    end = piece.end;
    timed = true;
    if (/\s$/.test(piece.text)) {
      flush();
    }
  }
  flush();
  return words;
}

function lineFromParagraph(paragraph: XmlNode): LyricLine | null {
  const pieces: Array<TtmlPiece> = [];
  const backingPieces: Array<TtmlPiece> = [];
  collectTtmlPieces(paragraph, pieces, backingPieces);
  const words = mergePiecesIntoWords(pieces);
  const backingWords = mergePiecesIntoWords(backingPieces);

  let backing: LyricLine | null = null;
  if (backingWords.length > 0) {
    const bgTexts: Array<string> = [];
    for (let i = 0; i < backingWords.length; i++) {
      bgTexts.push(backingWords[i].text);
    }
    backing = line(backingWords[0].startMs, bgTexts.join(' '), { words: backingWords });
  }

  if (words.length === 0) {
    const text = paragraph.textContent().trim();
    const begin = ttmlTime(paragraph.getAttribute('begin'));
    if (begin === null || text.length === 0) {
      return null;
    }
    const end = ttmlTime(paragraph.getAttribute('end'));
    const sungUntil: number | null = (end !== null && end > begin) ? end : null;
    return line(begin, text, { sungUntilMs: sungUntil });
  }

  const pBegin = ttmlTime(paragraph.getAttribute('begin'));
  const begin: number = pBegin !== null ? pBegin : words[0].startMs;
  const wordTexts: Array<string> = [];
  for (let i = 0; i < words.length; i++) {
    wordTexts.push(words[i].text);
  }
  return line(Math.min(begin, words[0].startMs), wordTexts.join(' '), {
    words: words,
    background: backing,
  });
}

/** Phân tích tài liệu TTML (Apple Music / LyricsPlus / lrc.red) thành danh sách LyricLine. */
export function parseTtml(ttml: string): Array<LyricLine> {
  try {
    const document = parseXmlTree(ttml);
    if (document === null) {
      return [];
    }
    const types: Record<string, string> = {};
    const agents = document.getElementsByTagName('agent');
    for (let i = 0; i < agents.length; i++) {
      const agent = agents[i];
      const id = agent.qualified('xml:id');
      const agentType = agent.getAttribute('type');
      if (id.length > 0 && agentType !== null && agentType.length > 0) {
        types[id] = agentType;
      }
    }

    const sung: Array<SungParagraphEntry> = [];
    const paragraphs = document.getElementsByTagName('p');
    for (let i = 0; i < paragraphs.length; i++) {
      const paragraph = paragraphs[i];
      const l = lineFromParagraph(paragraph);
      if (l !== null) {
        const agentAttr = paragraph.qualified('ttm:agent');
        sung.push(new SungParagraphEntry(l, agentAttr.length > 0 ? agentAttr : null));
      }
    }

    sung.sort((a: SungParagraphEntry, b: SungParagraphEntry): number => a.lyricLine.timeMs - b.lyricLine.timeMs);

    const agentList: Array<string | null> = [];
    for (let i = 0; i < sung.length; i++) {
      agentList.push(sung[i].agent);
    }
    const sides = lineAlignments(agentList, types);

    const aligned: Array<LyricLine> = [];
    for (let i = 0; i < sung.length; i++) {
      aligned.push(copyLyricLine(sung[i].lyricLine, { alignment: sides[i] }));
    }
    return withInstrumentalGaps(aligned);
  } catch (_e) {
    return [];
  }
}

// ---- Enhanced (A2) LRC (EnhancedLrc.kt) -----------------------------------------------------

const A2_LINE_REGEX: RegExp = /^\[(\d{1,3}):(\d{2})[.:](\d{2,3})\](.*)$/;
const A2_WORD_REGEX: RegExp = /<(\d{1,3}):(\d{2})[.:](\d{2,3})>([^<]*)/g;
const TAIL_MS: number = 800;

function parseLrcStamp(minutes: string, seconds: string, fraction: string): number {
  const fractionMs: number = fraction.length === 3 ? Number(fraction) : Number(fraction) * 10;
  return Number(minutes) * 60000 + Number(seconds) * 1000 + fractionMs;
}

class EnhancedLrcRow {
  timeMs: number;
  words: Array<RegExpMatchArray>;
  plain: string;

  constructor(timeMs: number, words: Array<RegExpMatchArray>, plain: string) {
    this.timeMs = timeMs;
    this.words = words;
    this.plain = plain;
  }
}

/** Phân tích định dạng Enhanced LRC (A2 có nhãn <mm:ss.xx> cho từng từ). Trả về [] nếu không có word stamp. */
export function parseEnhancedLrc(lrc: string): Array<LyricLine> {
  const rawLines = lrc.split(/\r?\n/);
  const rows: Array<EnhancedLrcRow> = [];
  let hasAnyWords: boolean = false;

  for (let i = 0; i < rawLines.length; i++) {
    const trimmed = rawLines[i].trim();
    const m = A2_LINE_REGEX.exec(trimmed);
    if (m === null) {
      continue;
    }
    const timeMs = parseLrcStamp(m[1], m[2], m[3]);
    const body = m[4];
    const wordMatches = Array.from(body.matchAll(A2_WORD_REGEX));
    if (wordMatches.length > 0) {
      hasAnyWords = true;
    }
    rows.push(new EnhancedLrcRow(timeMs, wordMatches, body.trim()));
  }

  if (!hasAnyWords) {
    return [];
  }

  rows.sort((a: EnhancedLrcRow, b: EnhancedLrcRow): number => a.timeMs - b.timeMs);

  const lines: Array<LyricLine> = [];
  for (let index = 0; index < rows.length; index++) {
    const row = rows[index];
    if (row.words.length === 0) {
      const text = decodeEntities(row.plain);
      if (text.length > 0) {
        lines.push(line(row.timeMs, text));
      }
      continue;
    }
    const last = row.words[row.words.length - 1];
    const lineEnd: number = (index + 1 < rows.length)
      ? rows[index + 1].timeMs
      : parseLrcStamp(last[1], last[2], last[3]) + TAIL_MS;

    const runs: Array<TimedRun> = [];
    for (let i = 0; i < row.words.length; i++) {
      const m = row.words[i];
      const startMs = parseLrcStamp(m[1], m[2], m[3]);
      const endMs = (i + 1 < row.words.length)
        ? parseLrcStamp(row.words[i + 1][1], row.words[i + 1][2], row.words[i + 1][3])
        : lineEnd;
      runs.push(new TimedRun(startMs, endMs, decodeEntities(m[4])));
    }

    const words = wordsFromRuns(runs);
    if (words.length === 0) {
      continue;
    }
    const wordTexts: Array<string> = [];
    for (let i = 0; i < words.length; i++) {
      wordTexts.push(words[i].text);
    }
    lines.push(line(Math.min(row.timeMs, words[0].startMs), wordTexts.join(' '), { words: words }));
  }

  return withInstrumentalGaps(lines);
}

// ---- Plain LRC (LrcLib.parseLrc) --------------------------------------------------------------

const LRC_STAMP_REGEX: RegExp = /\[(\d{1,3}):(\d{2})[.:](\d{2,3})\]/;
const WORD_STAMP_REGEX: RegExp = /<(\d{1,3}):(\d{2})[.:](\d{2,3})>/g;
const ALIGNMENT_MARKER: string = '<R>';

/** Phân tích định dạng LRC chuẩn (hỗ trợ nhiều mốc thời gian trên 1 dòng như [00:12.00][00:45.00]Chorus). */
export function parseLrc(lrc: string): Array<LyricLine> {
  const all: Array<LyricLine> = [];
  const rawLines = lrc.split(/\r?\n/);

  for (let r = 0; r < rawLines.length; r++) {
    const raw = rawLines[r];
    const match = LRC_STAMP_REGEX.exec(raw);
    if (match === null) {
      continue;
    }
    const stamps: Array<RegExpExecArray> = [match];
    let end: number = match.index + match[0].length;
    let next = LRC_STAMP_REGEX.exec(raw.slice(end));
    while (next !== null && next.index === 0) {
      stamps.push(next);
      end += next[0].length;
      next = LRC_STAMP_REGEX.exec(raw.slice(end));
    }

    let body = raw.slice(end);
    let alignment: LyricAlignment = 'start';
    if (body.startsWith(ALIGNMENT_MARKER)) {
      body = body.slice(ALIGNMENT_MARKER.length);
      alignment = 'end';
    }

    const marks = Array.from(body.matchAll(WORD_STAMP_REGEX));
    const runs: Array<TimedRun> = [];
    for (let i = 0; i < marks.length; i++) {
      const mark = marks[i];
      const markIndex: number = mark.index !== undefined ? mark.index : 0;
      const until: number = (i + 1 < marks.length && marks[i + 1].index !== undefined)
        ? (marks[i + 1].index as number)
        : body.length;
      const startMs = parseLrcStamp(mark[1], mark[2], mark[3]);
      const endMs = (i + 1 < marks.length)
        ? parseLrcStamp(marks[i + 1][1], marks[i + 1][2], marks[i + 1][3])
        : startMs;
      const sliceText = body.slice(markIndex + mark[0].length, until);
      runs.push(new TimedRun(startMs, endMs, sliceText));
    }

    const cleanText = body.replace(WORD_STAMP_REGEX, '').trim();
    for (let s = 0; s < stamps.length; s++) {
      const at = stamps[s];
      const stampMs = parseLrcStamp(at[1], at[2], at[3]);
      const words: Array<LyricWord> = marks.length > 0 ? wordsFromRuns(runs) : [];
      all.push(line(stampMs, cleanText, { words: words, alignment: alignment }));
    }
  }

  all.sort((a: LyricLine, b: LyricLine): number => a.timeMs - b.timeMs);

  const kept: Array<LyricLine> = [];
  for (let index = 0; index < all.length; index++) {
    const l = all[index];
    if (l.text.length > 0) {
      kept.push(l);
      continue;
    }
    const next = (index + 1 < all.length) ? all[index + 1] : null;
    if (next === null || next.timeMs - l.timeMs >= MIN_GAP_MS) {
      kept.push(l);
    }
  }

  if (kept.length > 0 && kept[0].text.length > 0 && kept[0].timeMs >= MIN_GAP_MS) {
    const withIntro: Array<LyricLine> = [line(0, '')];
    for (let i = 0; i < kept.length; i++) {
      withIntro.push(kept[i]);
    }
    return withIntro;
  }
  return kept;
}

// ---- QQ/QRC và NetEase YRC (KaraokeLrc) ------------------------------------------------------

const KARAOKE_LINE_REGEX: RegExp = /^\[(\d{1,8}),(\d{1,8})\](.*)$/;
const PREFIX_WORD_REGEX: RegExp = /\((\d{1,8}),(\d{1,8})(?:,\d{1,8})?\)([^()]*)/g;
const SUFFIX_WORD_REGEX: RegExp = /([^()]*)\((\d{1,8}),(\d{1,8})(?:,\d{1,8})?\)/g;
const KARAOKE_TIME_REGEX: RegExp = /\(\d{1,8},\d{1,8}(?:,\d{1,8})?\)/g;
const LYRIC_CONTENT_REGEX: RegExp = /LyricContent\s*=\s*"([^"]*)"/i;

function karaokeContent(raw: string): string {
  const match = LYRIC_CONTENT_REGEX.exec(raw);
  if (match !== null && match[1] !== undefined) {
    return match[1]
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'")
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&');
  }
  return raw;
}

export function looksLikeKaraoke(raw: string): boolean {
  const lines = karaokeContent(raw).split(/\r?\n/);
  const prefixTest = new RegExp(PREFIX_WORD_REGEX.source);
  const suffixTest = new RegExp(SUFFIX_WORD_REGEX.source);
  for (let i = 0; i < lines.length; i++) {
    const m = KARAOKE_LINE_REGEX.exec(lines[i].trim());
    if (m !== null && m[3] !== undefined) {
      const body = m[3];
      if (prefixTest.test(body) || suffixTest.test(body)) {
        return true;
      }
    }
  }
  return false;
}

function totalWordChars(words: Array<LyricWord>): number {
  let count: number = 0;
  for (let i = 0; i < words.length; i++) {
    count += words[i].text.length;
  }
  return count;
}

/** Phân tích định dạng Karaoke QRC (QQ Music) và YRC (NetEase). */
export function parseKaraoke(raw: string): Array<LyricLine> {
  const rows: Array<LyricLine> = [];
  const sourceLines = karaokeContent(raw).split(/\r?\n/);

  for (let i = 0; i < sourceLines.length; i++) {
    const match = KARAOKE_LINE_REGEX.exec(sourceLines[i].trim());
    if (match === null) {
      continue;
    }
    const lineStart = Number(match[1]);
    const lineDuration = Number(match[2]);
    const body = match[3];

    const prefixMatches = Array.from(body.matchAll(PREFIX_WORD_REGEX));
    const prefixRuns: Array<TimedRun> = [];
    for (let j = 0; j < prefixMatches.length; j++) {
      const pm = prefixMatches[j];
      const st = Number(pm[1]);
      const dur = Number(pm[2]);
      prefixRuns.push(new TimedRun(st, st + dur, decodeEntities(pm[3])));
    }

    const suffixMatches = Array.from(body.matchAll(SUFFIX_WORD_REGEX));
    const suffixRuns: Array<TimedRun> = [];
    for (let j = 0; j < suffixMatches.length; j++) {
      const sm = suffixMatches[j];
      const st = Number(sm[2]);
      const dur = Number(sm[3]);
      suffixRuns.push(new TimedRun(st, st + dur, decodeEntities(sm[1])));
    }

    const prefixed = wordsFromRuns(prefixRuns);
    const suffixed = wordsFromRuns(suffixRuns);
    const words = totalWordChars(prefixed) >= totalWordChars(suffixed) ? prefixed : suffixed;
    if (words.length === 0) {
      continue;
    }
    const text = decodeEntities(body.replace(KARAOKE_TIME_REGEX, '')).trim();
    if (text.length === 0) {
      continue;
    }
    rows.push(line(Math.min(lineStart, words[0].startMs), text, {
      words: words,
      sungUntilMs: lineDuration > 0 ? lineStart + lineDuration : null,
    }));
  }

  rows.sort((a: LyricLine, b: LyricLine): number => a.timeMs - b.timeMs);
  return withInstrumentalGaps(rows);
}

// ---- ProviderLyrics.kt (unwrap & parseProvider) ---------------------------------------------

const CONTENT_KEYS: Array<string> = [
  'ttml', 'ttmlContent', 'lyrics', 'lrc', 'content', 'text', 'plainLyrics', 'syncedLyrics',
  'line', 'lines', 'lyric', 'data', 'result', 'response',
];

function extractFromJsonValue(value: Object | null | undefined): string | null {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value === 'string') {
    const text = value.trim();
    const nested = safeJsonParse(text);
    if (nested !== null && typeof nested === 'object') {
      return extractFromJsonValue(nested);
    }
    return text;
  }
  const arr = asJsonArray(value);
  if (arr !== null) {
    const parts: Array<string> = [];
    for (let i = 0; i < arr.length; i++) {
      const extracted = extractFromJsonValue(arr[i]);
      if (extracted !== null && extracted.length > 0) {
        parts.push(extracted);
      }
    }
    return parts.length > 0 ? parts.join('\n') : null;
  }
  const obj = asJsonRecord(value);
  if (obj !== null) {
    const isError = getBooleanField(obj, 'isError');
    const ok = getBooleanField(obj, 'ok');
    const errField = getRecordField(obj, 'error');
    if (
      isError === true ||
      ok === false ||
      (errField !== undefined && errField !== null && errField !== false && errField !== '')
    ) {
      return null;
    }
    for (let i = 0; i < CONTENT_KEYS.length; i++) {
      const key = CONTENT_KEYS[i];
      const fieldVal = getRecordField(obj, key);
      if (fieldVal !== undefined) {
        const found = extractFromJsonValue(fieldVal);
        if (found !== null && found.length > 0) {
          return found;
        }
      }
    }
    const fromMeta = extractFromJsonValue(getRecordField(obj, 'metadata'));
    if (fromMeta !== null) {
      return fromMeta;
    }
    return extractFromJsonValue(getRecordField(obj, 'words'));
  }
  return null;
}

/** Bóc tách chuỗi lyrics từ một hoặc nhiều lớp JSON envelope hoặc markdown code fence. */
export function unwrap(raw: string): string | null {
  let value = raw.replace(/\uFEFF/g, '').trim();
  if (value.startsWith('```')) {
    const lines = value.split('\n').slice(1);
    if (lines.length > 0 && lines[lines.length - 1].trim() === '```') {
      lines.pop();
    }
    value = lines.join('\n').trim();
  }
  if (value.length === 0) {
    return null;
  }
  const parsedJson = safeJsonParse(value);
  if (parsedJson !== null) {
    const extracted = extractFromJsonValue(parsedJson);
    if (extracted !== null) {
      const trimmed = extracted.trim();
      return trimmed.length > 0 ? trimmed : null;
    }
    return null;
  }
  return value;
}

function unescapeTtml(value: string): string {
  if (/&lt;tt/i.test(value)) {
    return value
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;|&apos;/g, "'")
      .replace(/&amp;/g, '&');
  }
  return value;
}

export function plainLines(content: string): Array<LyricLine> {
  if (/\b(?:lyrics? (?:not found|unavailable)|error)\b/i.test(content)) {
    return [];
  }
  const rawLines = content.split(/\r?\n/);
  const out: Array<LyricLine> = [];
  for (let i = 0; i < rawLines.length; i++) {
    const l = rawLines[i].trim();
    if (l.length > 0 && !/^\[[A-Za-z]+:.*\]$/.test(l)) {
      out.push(line(0, l));
    }
  }
  return out;
}

export class ParsedLyrics {
  lines: Array<LyricLine>;
  ttml: string | null;

  constructor(lines: Array<LyricLine>, ttml: string | null = null) {
    this.lines = lines;
    this.ttml = ttml;
  }
}

/** Tự động nhận diện và phân tích mọi định dạng lyrics trả về từ provider (TTML, Karaoke, Enhanced LRC, LRC, Plain). */
export function parseProvider(raw: string): ParsedLyrics | null {
  const unwrapped = unwrap(raw);
  if (unwrapped === null) {
    return null;
  }
  const content = unescapeTtml(unwrapped);
  let lines: Array<LyricLine> = [];
  let ttml: string | null = null;

  if (/<tt(?:\s|>)/i.test(content) || /http:\/\/www\.w3\.org\/ns\/ttml/i.test(content)) {
    lines = parseTtml(content);
    ttml = content;
  } else if (looksLikeKaraoke(content)) {
    lines = parseKaraoke(content);
  } else if (content.trimStart().startsWith('<')) {
    lines = [];
  } else {
    lines = parseEnhancedLrc(content);
    if (lines.length === 0) {
      lines = parseLrc(content);
    }
    if (lines.length === 0) {
      lines = plainLines(content);
    }
  }

  for (let i = 0; i < lines.length; i++) {
    if (lines[i].text.trim().length > 0) {
      return new ParsedLyrics(lines, ttml);
    }
  }
  return null;
}

// ---- Các hàm Parser chuyên biệt cho từng Provider (PaxSenix, LyricsPlus, Musixmatch, KuGou, Genius) ----

function findPaxSenixRows(node: Object | null | undefined): Array<JsonRecord> | null {
  const arr = asJsonArray(node);
  if (arr !== null) {
    for (let i = 0; i < arr.length; i++) {
      const found = findPaxSenixRows(arr[i]);
      if (found !== null) {
        return found;
      }
    }
    return null;
  }
  const obj = asJsonRecord(node);
  if (obj !== null) {
    const contentArr = asJsonArray(getRecordField(obj, 'content'));
    if (contentArr !== null) {
      const records: Array<JsonRecord> = [];
      let hasTimestamp = false;
      for (let i = 0; i < contentArr.length; i++) {
        const rec = asJsonRecord(contentArr[i]);
        if (rec !== null) {
          records.push(rec);
          if (getRecordField(rec, 'timestamp') !== undefined) {
            hasTimestamp = true;
          }
        }
      }
      if (hasTimestamp) {
        return records;
      }
    }
    const keys = Object.keys(obj);
    for (let i = 0; i < keys.length; i++) {
      const found = findPaxSenixRows(obj[keys[i]]);
      if (found !== null) {
        return found;
      }
    }
  }
  return null;
}

/** Phân tích JSON Apple Music có nhãn âm tiết từ PaxSenix (PaxSenix.parseTimedApple). */
export function parsePaxSenixTimed(raw: string): Array<LyricLine> | null {
  const root = safeJsonParse(raw);
  const rows = findPaxSenixRows(root);
  if (rows === null) {
    return null;
  }
  const lines: Array<LyricLine> = [];
  for (let index = 0; index < rows.length; index++) {
    const row = rows[index];
    const start = getNumberField(row, 'timestamp');
    const wordArr = asJsonArray(getRecordField(row, 'text'));
    if (start === null || wordArr === null) {
      continue;
    }
    const wordRows: Array<JsonRecord> = [];
    const texts: Array<string> = [];
    for (let i = 0; i < wordArr.length; i++) {
      const wRec = asJsonRecord(wordArr[i]);
      if (wRec !== null) {
        wordRows.push(wRec);
        const wText = getStringField(wRec, 'text');
        if (wText !== null) {
          texts.push(wText);
        }
      }
    }
    if (texts.length === 0) {
      continue;
    }
    const nextLine: number | null = (index + 1 < rows.length)
      ? getNumberField(rows[index + 1], 'timestamp')
      : null;

    const runs: Array<TimedRun> = [];
    for (let i = 0; i < wordRows.length; i++) {
      const word = wordRows[i];
      const rawText = getStringField(word, 'text');
      const text = rawText !== null ? rawText.trim() : '';
      const wordTs = getNumberField(word, 'timestamp');
      if (text.length === 0 || wordTs === null) {
        continue;
      }
      const wordEnd = getNumberField(word, 'endtime');
      const nextWordTs: number | null = (i + 1 < wordRows.length)
        ? getNumberField(wordRows[i + 1], 'timestamp')
        : null;
      const end: number = wordEnd !== null
        ? wordEnd
        : (nextWordTs !== null ? nextWordTs : (nextLine !== null ? nextLine : wordTs + 800));
      const isPart = getBooleanField(word, 'part') === true;
      runs.push(new TimedRun(wordTs, end, isPart ? text : `${text} `));
    }

    const timed = wordsFromRuns(runs, true);
    let nonBlankTextCount = 0;
    for (let i = 0; i < texts.length; i++) {
      if (texts[i].trim().length > 0) {
        nonBlankTextCount++;
      }
    }
    const untimed: boolean = runs.length !== nonBlankTextCount;
    const firstStart: number = timed.length > 0 ? timed[0].startMs : start;

    let lineText = '';
    if (untimed) {
      const trimmedTexts: Array<string> = [];
      for (let i = 0; i < texts.length; i++) {
        trimmedTexts.push(texts[i].trim());
      }
      lineText = trimmedTexts.join(' ');
    } else {
      const timedTexts: Array<string> = [];
      for (let i = 0; i < timed.length; i++) {
        timedTexts.push(timed[i].text);
      }
      lineText = timedTexts.join(' ');
    }

    lines.push(line(Math.min(start, firstStart), lineText, {
      words: untimed ? [] : timed,
      sungUntilMs: nextLine,
    }));
  }

  const out = withInstrumentalGaps(lines);
  for (let i = 0; i < out.length; i++) {
    if (out[i].text.trim().length > 0) {
      return out;
    }
  }
  return null;
}

class LyricsPlusSungEntry {
  lyricLine: LyricLine;
  element: Object | null | undefined;

  constructor(lyricLine: LyricLine, element: Object | null | undefined) {
    this.lyricLine = lyricLine;
    this.element = element;
  }
}

/** Phân tích JSON v2 của LyricsPlus (hỗ trợ syllabus âm tiết và metadata agents). */
export function parseLyricsPlus(rawJson: Object | null | undefined): Array<LyricLine> {
  const response = asJsonRecord(rawJson);
  if (response === null) {
    return [];
  }
  const lyricsArr = asJsonArray(getRecordField(response, 'lyrics'));
  if (lyricsArr === null) {
    return [];
  }

  const sung: Array<LyricsPlusSungEntry> = [];
  for (let i = 0; i < lyricsArr.length; i++) {
    const l = asJsonRecord(lyricsArr[i]);
    if (l === null) {
      continue;
    }
    const time = getNumberField(l, 'time');
    if (time === null) {
      continue;
    }
    const syllabusArr = asJsonArray(getRecordField(l, 'syllabus'));
    const runs: Array<TimedRun> = [];
    if (syllabusArr !== null) {
      for (let j = 0; j < syllabusArr.length; j++) {
        const s = asJsonRecord(syllabusArr[j]);
        if (s === null) {
          continue;
        }
        const sText = getStringField(s, 'text');
        const sTime = getNumberField(s, 'time');
        const sDur = getNumberField(s, 'duration');
        if (sText !== null && sTime !== null) {
          runs.push(new TimedRun(sTime, sTime + (sDur !== null ? sDur : 0), sText));
        }
      }
    }
    const words = wordsFromRuns(runs, true);
    let built: LyricLine | null = null;
    if (words.length > 0) {
      const wordTexts: Array<string> = [];
      for (let k = 0; k < words.length; k++) {
        wordTexts.push(words[k].text);
      }
      built = line(Math.min(time, words[0].startMs), wordTexts.join(' '), { words: words });
    } else {
      const lText = getStringField(l, 'text');
      if (lText !== null && lText.trim().length > 0) {
        const dur = getNumberField(l, 'duration');
        built = line(time, lText.trim(), {
          sungUntilMs: (dur !== null && dur > 0) ? time + dur : null,
        });
      }
    }
    if (built !== null) {
      sung.push(new LyricsPlusSungEntry(built, getRecordField(l, 'element')));
    }
  }

  sung.sort((a: LyricsPlusSungEntry, b: LyricsPlusSungEntry): number => a.lyricLine.timeMs - b.lyricLine.timeMs);

  const types: Record<string, string> = {};
  const metadata = asJsonRecord(getRecordField(response, 'metadata'));
  const agents = metadata !== null ? asJsonRecord(getRecordField(metadata, 'agents')) : null;
  if (agents !== null) {
    const ids = Object.keys(agents);
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i];
      const agentObj = asJsonRecord(agents[id]);
      if (agentObj !== null) {
        const aType = getStringField(agentObj, 'type');
        const aAlias = getStringField(agentObj, 'alias');
        if (aType !== null) {
          types[aAlias !== null ? aAlias : id] = aType;
        }
      }
    }
  }

  const singers: Array<string | null> = [];
  for (let i = 0; i < sung.length; i++) {
    const elemRec = asJsonRecord(sung[i].element);
    singers.push(elemRec !== null ? getStringField(elemRec, 'singer') : null);
  }
  const sides = lineAlignments(singers, types);

  const aligned: Array<LyricLine> = [];
  for (let i = 0; i < sung.length; i++) {
    const entry = sung[i];
    const elemArr = asJsonArray(entry.element);
    let opposite = false;
    if (elemArr !== null) {
      for (let j = 0; j < elemArr.length; j++) {
        if (elemArr[j] === 'opposite' || elemArr[j] === 'right') {
          opposite = true;
          break;
        }
      }
    }
    const side: LyricAlignment = (sides[i] === 'end' || opposite) ? 'end' : 'start';
    aligned.push(copyLyricLine(entry.lyricLine, { alignment: side }));
  }
  return withInstrumentalGaps(aligned);
}

/** Phân tích định dạng RichSync của Musixmatch (Musixmatch.parseRichSyncBody). */
export function parseRichSync(body: string): Array<LyricLine> {
  const root = safeJsonParse(body);
  const entries = asJsonArray(root);
  if (entries === null) {
    return [];
  }
  const lines: Array<LyricLine> = [];

  for (let i = 0; i < entries.length; i++) {
    const entry = asJsonRecord(entries[i]);
    if (entry === null) {
      continue;
    }
    const ts = getNumberField(entry, 'ts');
    const te = getNumberField(entry, 'te');
    if (ts === null || te === null) {
      continue;
    }
    const lineStart = Math.trunc(ts * 1000);
    const lineEnd = Math.max(lineStart, Math.trunc(te * 1000));
    let previous = lineStart;

    const fragmentsArr = asJsonArray(getRecordField(entry, 'l'));
    const fragments: Array<JsonRecord> = [];
    if (fragmentsArr !== null) {
      for (let j = 0; j < fragmentsArr.length; j++) {
        const fRec = asJsonRecord(fragmentsArr[j]);
        if (fRec !== null) {
          fragments.push(fRec);
        }
      }
    }

    const runs: Array<TimedRun> = [];
    for (let index = 0; index < fragments.length; index++) {
      const fragment = fragments[index];
      const c = getStringField(fragment, 'c');
      const o = getNumberField(fragment, 'o');
      if (c === null || c.length === 0 || o === null) {
        continue;
      }
      const start = Math.max(lineStart, previous, Math.trunc((ts + o) * 1000));
      let until = lineEnd;
      if (index + 1 < fragments.length) {
        const nextO = getNumberField(fragments[index + 1], 'o');
        if (nextO !== null) {
          until = Math.trunc((ts + nextO) * 1000);
        }
      }
      previous = start;
      runs.push(new TimedRun(start, Math.max(start, Math.min(lineEnd, until)), c));
    }

    const words = wordsFromRuns(runs, true);
    const xField = getStringField(entry, 'x');
    let text = xField !== null ? xField.trim() : '';
    if (text.length === 0) {
      const wordTexts: Array<string> = [];
      for (let k = 0; k < words.length; k++) {
        wordTexts.push(words[k].text);
      }
      text = wordTexts.join(' ');
    }
    if (text.length > 0) {
      const firstWordStart = words.length > 0 ? words[0].startMs : lineStart;
      lines.push(line(Math.min(lineStart, firstWordStart), text, {
        words: words,
        sungUntilMs: lineEnd > lineStart ? lineEnd : null,
      }));
    }
  }

  lines.sort((a: LyricLine, b: LyricLine): number => a.timeMs - b.timeMs);
  return withInstrumentalGaps(lines);
}

const KUGOU_STAMPED_REGEX: RegExp = /^\[\d{2}:\d{2}\.\d{2,3}\].*/;
const KUGOU_CREDIT_REGEX: RegExp = /.+\][^[]+[:：].+/;
const KUGOU_STAMP_GLOBAL: RegExp = /\[\d{2}:\d{2}\.\d{2,3}\]/g;
const KUGOU_INSTRUMENTAL_REGEX: RegExp = /纯音乐.*欣赏/;

/** Cắt bỏ các dòng credit mở đầu và kết thúc ("作词: …", "作曲: …") trong file LRC của KuGou. */
export function stripKugouCredits(lrc: string): string {
  const rawLines = lrc.split(/\r?\n/);
  const lines: Array<string> = [];
  for (let i = 0; i < rawLines.length; i++) {
    if (KUGOU_STAMPED_REGEX.test(rawLines[i])) {
      lines.push(rawLines[i]);
    }
  }
  if (lines.length === 0) {
    return '';
  }
  let head: number = 0;
  for (let i = Math.min(30, lines.length - 1); i >= 0; i--) {
    if (KUGOU_CREDIT_REGEX.test(lines[i])) {
      head = i + 1;
      break;
    }
  }
  const body = lines.slice(head);
  let tail: number = 0;
  for (let i = 0; i <= Math.min(30, body.length - 1); i++) {
    if (KUGOU_CREDIT_REGEX.test(body[body.length - 1 - i])) {
      tail = i + 1;
      break;
    }
  }
  return body.slice(0, body.length - tail).join('\n');
}

/** Kiểm tra xem nội dung LRC của KuGou có phải thông báo nhạc không lời ("纯音乐，请欣赏") hay không. */
export function isKugouInstrumentalNotice(lrc: string): boolean {
  const rawLines = lrc.split(/\r?\n/);
  const lines: Array<string> = [];
  for (let i = 0; i < rawLines.length; i++) {
    const stripped = rawLines[i].replace(KUGOU_STAMP_GLOBAL, '').trim();
    if (stripped.length > 0) {
      lines.push(stripped);
    }
  }
  if (lines.length === 0) {
    return false;
  }
  for (let i = 0; i < lines.length; i++) {
    if (!KUGOU_INSTRUMENTAL_REGEX.test(lines[i])) {
      return false;
    }
  }
  return true;
}

/** Trích xuất lời bài hát từ HTML trang Genius (không dùng DOMParser). */
export function parseGeniusHtml(html: string): Array<LyricLine> {
  const containerChunks: Array<string> = [];
  const dataContainerRegex = /<div[^>]*data-lyrics-container="true"[^>]*>([\s\S]*?)<\/div>/gi;
  let m = dataContainerRegex.exec(html);
  while (m !== null) {
    containerChunks.push(m[1]);
    m = dataContainerRegex.exec(html);
  }
  if (containerChunks.length === 0) {
    const legacyRegex = /<div[^>]*class="[^"]*\blyrics\b[^"]*"[^>]*>([\s\S]*?)<\/div>/gi;
    let lm = legacyRegex.exec(html);
    while (lm !== null) {
      containerChunks.push(lm[1]);
      lm = legacyRegex.exec(html);
    }
  }
  if (containerChunks.length === 0) {
    return [];
  }

  let combinedText = '';
  for (let i = 0; i < containerChunks.length; i++) {
    let chunk = containerChunks[i];
    chunk = chunk.replace(/<(script|style|button)[^>]*>[\s\S]*?<\/\1>/gi, '');
    chunk = chunk.replace(/<[^>]*data-exclude-from-selection="true"[^>]*>[\s\S]*?<\/div>/gi, '');
    chunk = chunk.replace(/<br\s*\/?>/gi, '\n');
    chunk = chunk.replace(/<[^>]+>/g, '');
    combinedText += `${chunk}\n`;
  }

  const cleaned = combinedText
    .replace(/[\u00A0\u200B\uFEFF]/g, ' ')
    .replace(/\d*You might also like/gi, '')
    .trim()
    .replace(/\d*Embed\s*$/i, '')
    .trim();

  const out: Array<LyricLine> = [];
  const rawLines = cleaned.split('\n');
  for (let i = 0; i < rawLines.length; i++) {
    const t = rawLines[i].trim().replace(/\d*Embed\s*$/i, '').trim();
    if (t.length === 0) {
      if (out.length > 0 && out[out.length - 1].text.length > 0) {
        out.push(line(0, ''));
      }
    } else {
      out.push(line(0, decodeEntities(t)));
    }
  }
  while (out.length > 0 && out[0].text.length === 0) {
    out.shift();
  }
  while (out.length > 0 && out[out.length - 1].text.length === 0) {
    out.pop();
  }
  return out;
}

// ---- TTML Writer & LRC / Enhanced LRC Writer (ttml.ts & LrcWriter.kt) -----------------------

function escapeXml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatTtmlClock(ms: number): string {
  return (Math.max(0, ms) / 1000).toFixed(3);
}

function spansOfWords(words: Array<LyricWord>): string {
  const wordSpans: Array<string> = [];
  for (let i = 0; i < words.length; i++) {
    const word = words[i];
    if (word.syllables.length === 0) {
      wordSpans.push(
        `<span begin="${formatTtmlClock(word.startMs)}" end="${formatTtmlClock(word.endMs)}">${escapeXml(word.text)}</span>`
      );
    } else {
      const sylSpans: Array<string> = [];
      for (let j = 0; j < word.syllables.length; j++) {
        const s = word.syllables[j];
        const subText = word.text.slice(s.startChar, s.endChar);
        sylSpans.push(
          `<span begin="${formatTtmlClock(s.startMs)}" end="${formatTtmlClock(s.endMs)}">${escapeXml(subText)}</span>`
        );
      }
      wordSpans.push(sylSpans.join(''));
    }
  }
  return wordSpans.join(' ');
}

/** Xuất danh sách LyricLine ra tài liệu XML TTML chuẩn Apple Music. */
export function writeTtml(lines: Array<LyricLine>, language: string = 'en'): string {
  const sung: Array<LyricLine> = [];
  let timed = false;
  let wordTimed = false;
  let duet = false;

  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (!isGap(l)) {
      sung.push(l);
      if (l.timeMs > 0 || l.words.length > 0) {
        timed = true;
      }
      if (l.words.length > 0) {
        wordTimed = true;
      }
      if (l.alignment === 'end') {
        duet = true;
      }
    }
  }

  const paragraphs: Array<string> = [];
  for (let index = 0; index < sung.length; index++) {
    const l = sung[index];
    const agent = duet ? ` ttm:agent="${l.alignment === 'end' ? 'v2' : 'v1'}"` : '';
    if (!timed) {
      paragraphs.push(`<p${agent}>${escapeXml(l.text)}</p>`);
      continue;
    }
    const nextTime: number | null = (index + 1 < sung.length) ? sung[index + 1].timeMs : null;
    if (l.words.length > 0) {
      const lastWordEnd = l.words[l.words.length - 1].endMs;
      const bgWords = l.background !== null ? l.background.words : [];
      const bgEnd = bgWords.length > 0 ? bgWords[bgWords.length - 1].endMs : 0;
      const lastEnd = Math.max(lastWordEnd, bgEnd);
      const backgroundSpan = bgWords.length > 0
        ? ` <span ttm:role="x-bg">${spansOfWords(bgWords)}</span>`
        : '';
      paragraphs.push(
        `<p begin="${formatTtmlClock(l.timeMs)}" end="${formatTtmlClock(lastEnd)}"${agent}>${spansOfWords(l.words)}${backgroundSpan}</p>`
      );
      continue;
    }
    const text = l.background !== null ? `${l.text} ${l.background.text}` : l.text;
    const end: number = l.sungUntilMs !== null
      ? l.sungUntilMs
      : (nextTime !== null ? nextTime : l.timeMs + 5000);
    paragraphs.push(
      `<p begin="${formatTtmlClock(l.timeMs)}" end="${formatTtmlClock(Math.max(end, l.timeMs))}"${agent}>${escapeXml(text)}</p>`
    );
  }

  const agentsXml = duet
    ? '<ttm:agent type="person" xml:id="v1"/><ttm:agent type="other" xml:id="v2"/>'
    : '';
  const timingMode = wordTimed ? 'Word' : (timed ? 'Line' : 'None');
  return (
    `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" ` +
    `xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xml:lang="${escapeXml(language)}" ` +
    `itunes:timing="${timingMode}">` +
    `<head><metadata>${agentsXml}</metadata></head><body><div>${paragraphs.join('')}</div></body></tt>`
  );
}

// ---- LrcWriter.kt (Xuất ra LRC thường và Enhanced LRC A2 để nhúng vào tag file nhạc) --------

function padTwoDigits(n: number): string {
  const s = Math.trunc(n).toString();
  return s.length < 2 ? `0${s}` : s;
}

function formatLrcClock(timeMs: number): string {
  const total = Math.max(0, Math.trunc(timeMs));
  const minutes = padTwoDigits(Math.floor(total / 60000));
  const seconds = padTwoDigits(Math.floor((total % 60000) / 1000));
  const centiseconds = padTwoDigits(Math.floor((total % 1000) / 10));
  return `${minutes}:${seconds}.${centiseconds}`;
}

function lrcLineStamp(timeMs: number): string {
  return `[${formatLrcClock(timeMs)}]`;
}

function lrcWordStamp(timeMs: number): string {
  return `<${formatLrcClock(timeMs)}>`;
}

function flattenedLineText(l: LyricLine): string {
  if (l.background !== null) {
    return `${l.text} ${l.background.text}`.trim();
  }
  return l.text;
}

/** Xuất danh sách LyricLine sang chuỗi LRC chuẩn `[mm:ss.xx]text` (LrcWriter.toLrc). */
export function toLrc(lines: Array<LyricLine>): string {
  if (lines.length === 0) {
    return '';
  }
  let anyTimed = false;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].timeMs > 0) {
      anyTimed = true;
      break;
    }
  }
  if (!anyTimed) {
    const plainOut: Array<string> = [];
    for (let i = 0; i < lines.length; i++) {
      plainOut.push(flattenedLineText(lines[i]));
    }
    return plainOut.join('\n');
  }
  const sorted = lines.slice().sort((a: LyricLine, b: LyricLine): number => a.timeMs - b.timeMs);
  const rows: Array<string> = [];
  for (let i = 0; i < sorted.length; i++) {
    rows.push(`${lrcLineStamp(sorted[i].timeMs)}${flattenedLineText(sorted[i])}`);
  }
  return rows.join('\n');
}

function timedRunsForLine(l: LyricLine): Array<LyricWord> {
  if (l.words.length === 0) {
    return [];
  }
  const out: Array<LyricWord> = l.words.slice();
  if (l.background !== null) {
    if (l.background.words.length > 0) {
      for (let i = 0; i < l.background.words.length; i++) {
        out.push(l.background.words[i]);
      }
    } else if (l.background.text.trim().length > 0) {
      out.push(new LyricWord(l.background.timeMs, endMsForBackground(l.background), l.background.text));
    }
  }
  return out;
}

function endMsForBackground(bg: LyricLine): number {
  if (bg.words.length > 0) {
    return bg.words[bg.words.length - 1].endMs;
  }
  return bg.sungUntilMs !== null ? bg.sungUntilMs : bg.timeMs;
}

function enhancedBodyForLine(l: LyricLine): string {
  const runs = timedRunsForLine(l);
  if (runs.length === 0) {
    return flattenedLineText(l);
  }
  let out = '';
  if (l.alignment === 'end') {
    out += ALIGNMENT_MARKER;
  }
  let previous = l.timeMs;
  let hasSyllables = false;
  let maxEnd = previous;

  for (let index = 0; index < runs.length; index++) {
    const word = runs[index];
    if (word.endMs > maxEnd) {
      maxEnd = word.endMs;
    }
    if (word.syllables.length === 0) {
      const start = Math.max(word.startMs, previous);
      out += `${lrcWordStamp(start)}${word.text}`;
      previous = start;
    } else {
      hasSyllables = true;
      for (let s = 0; s < word.syllables.length; s++) {
        const syllable = word.syllables[s];
        const start = Math.max(syllable.startMs, previous);
        out += `${lrcWordStamp(start)}${word.text.slice(syllable.startChar, syllable.endChar)}`;
        previous = start;
      }
    }
    if (index !== runs.length - 1) {
      out += ' ';
    }
  }
  if (hasSyllables) {
    out += ' ';
  }
  out += lrcWordStamp(Math.max(maxEnd, previous));
  return out;
}

/** Xuất danh sách LyricLine sang chuỗi Enhanced LRC (A2 `<mm:ss.xx>`) giữ nguyên word/syllable timings. */
export function toEnhancedLrc(lines: Array<LyricLine>): string {
  if (lines.length === 0) {
    return '';
  }
  let anyWordSynced = false;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (l.words.length > 0 || (l.background !== null && l.background.words.length > 0)) {
      anyWordSynced = true;
      break;
    }
  }
  if (!anyWordSynced) {
    return '';
  }
  const sorted = lines.slice().sort((a: LyricLine, b: LyricLine): number => a.timeMs - b.timeMs);
  const rows: Array<string> = [];
  for (let i = 0; i < sorted.length; i++) {
    rows.push(`${lrcLineStamp(sorted[i].timeMs)}${enhancedBodyForLine(sorted[i])}`);
  }
  return rows.join('\n');
}