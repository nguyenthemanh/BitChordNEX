import { describe, it, expect } from '@ohos/hypium';
import { LyricLine, LyricWord, withBackgroundVocals } from '../main/ets/core/lyricsmodel';
import {
  decodeEntities,
  isKugouInstrumentalNotice,
  parseEnhancedLrc,
  parseKaraoke,
  parseLrc,
  parsePaxSenixTimed,
  parseProvider,
  parseTtml,
  stripKugouCredits,
  toEnhancedLrc,
  writeTtml,
} from '../main/ets/core/lyricsparser';

const APPLE: string = '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">' +
  '<head><metadata><ttm:agent type="person" xml:id="v1"/><ttm:agent type="person" xml:id="v2"/></metadata></head>' +
  '<body><div>' +
  '<p begin="27.395" end="29.0" ttm:agent="v1">' +
  '<span begin="27.395" end="27.549">I</span> <span begin="27.549" end="27.740">been</span> ' +
  '<span begin="27.8" end="28.0">e</span><span begin="28.0" end="28.6">nough</span>' +
  '<span ttm:role="x-bg"><span begin="28.6" end="29.0">(ooh)</span></span></p>' +
  '<p begin="31.0" end="32.0" ttm:agent="v2"><span begin="31.0" end="32.0">Hey</span></p>' +
  '</div></body></tt>';

function sungLines(lines: Array<LyricLine>): Array<LyricLine> {
  const out: Array<LyricLine> = [];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].text.length > 0) {
      out.push(lines[i]);
    }
  }
  return out;
}

function wordTexts(words: Array<LyricWord>): string {
  const parts: Array<string> = [];
  for (let i = 0; i < words.length; i++) {
    parts.push(words[i].text);
  }
  return parts.join('|');
}

function syllableKey(word: LyricWord): string {
  const parts: Array<string> = [];
  for (let i = 0; i < word.syllables.length; i++) {
    const s = word.syllables[i];
    parts.push(`${s.startMs},${s.endMs},${s.startChar},${s.endChar}`);
  }
  return parts.join(';');
}

function lineTexts(lines: Array<LyricLine>): string {
  const parts: Array<string> = [];
  for (let i = 0; i < lines.length; i++) {
    parts.push(lines[i].text);
  }
  return parts.join('|');
}

export default function lyricsParserTest() {
  describe('lyricsParserTest', () => {
    it('parseTtmlGluesSyllablesAndBackground', 0, () => {
      const lines = parseTtml(APPLE);
      expect(lines[0].timeMs).assertEqual(0);
      expect(lines[0].text).assertEqual('');
      const sung = sungLines(lines);
      expect(sung[0].text).assertEqual('I been enough');
      expect(sung[0].words[2].text).assertEqual('enough');
      expect(sung[0].words[2].startMs).assertEqual(27800);
      expect(sung[0].words[2].endMs).assertEqual(28600);
      expect(syllableKey(sung[0].words[2])).assertEqual('27800,28000,0,1;28000,28600,1,6');
      const backing = sung[0].background;
      expect(backing !== null).assertTrue();
      if (backing !== null) {
        expect(backing.text).assertEqual('(ooh)');
      }
      expect(wordTexts(sung[0].words)).assertEqual('I|been|enough');
      expect(sung[0].alignment).assertEqual('start');
      expect(sung[1].alignment).assertEqual('end');
    });

    it('writeTtmlRoundTripsWordsBackgroundAndSides', 0, () => {
      const original = sungLines(parseTtml(APPLE));
      const again = sungLines(parseTtml(writeTtml(original)));
      expect(lineTexts(again)).assertEqual(lineTexts(original));
      expect(syllableKey(again[0].words[2])).assertEqual(syllableKey(original[0].words[2]));
      const againBg = again[0].background;
      expect(againBg !== null).assertTrue();
      if (againBg !== null) {
        expect(againBg.text).assertEqual('(ooh)');
      }
      expect(again[0].alignment).assertEqual('start');
      expect(again[1].alignment).assertEqual('end');
    });

    it('parseEnhancedLrcReadsWordStamps', 0, () => {
      const lines = parseEnhancedLrc('[00:27.39]<00:27.39>I <00:27.54>been <00:27.74>tryna\n[00:30.00]<00:30.00>call');
      expect(lineTexts(lines)).assertEqual('|I been tryna|call');
      expect(lines[1].words[2].startMs).assertEqual(27740);
      expect(lines[1].words[2].endMs).assertEqual(30000);
    });

    it('parseEnhancedLrcGluesSyllablesAndKeepsUnspacedStamps', 0, () => {
      const glued = sungLines(parseEnhancedLrc('[00:30.18]<00:30.189>long <00:31.839>e<00:31.996>nough<00:32.529>'));
      expect(glued[0].text).assertEqual('long enough');
      expect(wordTexts(glued[0].words)).assertEqual('long|enough');
      expect(syllableKey(glued[0].words[1])).assertEqual('31839,31996,0,1;31996,32529,1,6');

      const separate = sungLines(parseEnhancedLrc('[00:01.00]<00:01.00>I<00:01.20>been<00:01.50>tryna<00:02.00>'));
      expect(separate[0].text).assertEqual('I been tryna');
      expect(wordTexts(separate[0].words)).assertEqual('I|been|tryna');
    });

    it('toEnhancedLrcRoundTripsSyllablesAtCentisecondResolution', 0, () => {
      const original = sungLines(parseEnhancedLrc('[00:30.18]<00:30.189>long <00:31.839>e<00:31.996>nough<00:32.529>'));
      const back = sungLines(parseLrc(toEnhancedLrc(original)));
      expect(back[0].text).assertEqual('long enough');
      expect(wordTexts(back[0].words)).assertEqual('long|enough');
      expect(syllableKey(back[0].words[1])).assertEqual('31830,31990,0,1;31990,32520,1,6');
    });

    it('parseLrcReadsRepeatedStampsAndDropsMetadata', 0, () => {
      const repeated = sungLines(parseLrc('[00:12.00][00:45.00]chorus\n[00:20.00]verse'));
      expect(repeated.length).assertEqual(3);
      expect(repeated[0].timeMs).assertEqual(12000);
      expect(repeated[0].text).assertEqual('chorus');
      expect(repeated[1].timeMs).assertEqual(20000);
      expect(repeated[1].text).assertEqual('verse');
      expect(repeated[2].timeMs).assertEqual(45000);
      expect(repeated[2].text).assertEqual('chorus');

      const plain = parseLrc('[ar:Someone]\n[00:01.00]one\n[00:02.00]\n[00:03.50]two');
      expect(lineTexts(plain)).assertEqual('one|two');
    });

    it('decodeEntitiesKeepsUnknownCodePoints', 0, () => {
      expect(decodeEntities('don&#x27;t &amp; won&#39;t')).assertEqual("don't & won't");
      const kept = decodeEntities('&#99999999999; &#x110000; &#128293;');
      expect(kept).assertEqual(`&#99999999999; &#x110000; ${String.fromCodePoint(128293)}`);
    });

    it('parseKaraokeReadsYrcAndQrc', 0, () => {
      const hello = parseKaraoke('[1000,2000](1000,500,0)Hel(1500,500,0)lo (2000,1000,0)there');
      expect(hello[0].timeMs).assertEqual(1000);
      expect(hello[0].text).assertEqual('Hello there');
      expect(hello[0].sungUntilMs).assertEqual(3000);

      const yrc = sungLines(parseKaraoke('[31000,1600](31000,839,0)long (31839,157,0)e(31996,533,0)nough'));
      expect(yrc[0].text).assertEqual('long enough');
      expect(wordTexts(yrc[0].words)).assertEqual('long|enough');
      expect(syllableKey(yrc[0].words[1])).assertEqual('31839,31996,0,1;31996,32529,1,6');

      const netease = sungLines(parseKaraoke('[1000,900](1000,400,0)sing(1400,500,0)along'));
      expect(netease[0].text).assertEqual('singalong');
      expect(netease[0].words[0].startMs).assertEqual(1000);
      expect(netease[0].words[1].startMs).assertEqual(1400);
      expect(netease[0].words[1].endMs).assertEqual(1900);

      const qq = sungLines(parseKaraoke('[1000,900]sing (1000,400,0)along(1400,500,0)'));
      expect(qq[0].text).assertEqual('sing along');
      expect(qq[0].words.length).assertEqual(2);

      const cjk = sungLines(parseKaraoke('[1000,900]我(1000,300,0)爱(1300,300,0)你(1600,300,0)'));
      expect(cjk[0].words.length).assertEqual(3);
      expect(cjk[0].words[0].syllables.length).assertEqual(0);
      expect(cjk[0].words[1].syllables.length).assertEqual(0);
      expect(cjk[0].words[2].syllables.length).assertEqual(0);
    });

    it('parseProviderUnwrapsTtmlAndRejectsErrors', 0, () => {
      const wrapped = parseProvider(`{"ttml":${JSON.stringify(APPLE)}}`);
      expect(wrapped !== null).assertTrue();
      if (wrapped !== null) {
        const ttml = wrapped.ttml;
        expect(ttml !== null).assertTrue();
        if (ttml !== null) {
          expect(ttml.indexOf('<tt') >= 0).assertTrue();
        }
        expect(sungLines(wrapped.lines)[0].words.length > 0).assertTrue();
      }
      expect(parseProvider('{"error":"not found"}')).assertNull();

      const content = '{"content":"<tt><body><div><p begin=\\"1.0\\" end=\\"2.0\\">' +
        '<span begin=\\"1.0\\" end=\\"1.4\\">sing </span><span begin=\\"1.4\\" end=\\"2.0\\">along</span>' +
        '</p></div></body></tt>"}';
      const apple = parseProvider(content);
      expect(apple !== null).assertTrue();
      if (apple !== null) {
        const line = sungLines(apple.lines)[0];
        expect(line.text).assertEqual('sing along');
        expect(line.words.length).assertEqual(2);
        expect(line.words[1].endMs).assertEqual(2000);
      }

      const qrc = parseProvider(
        '<QrcInfos><LyricInfo LyricContent="[1000,900]sing (1000,400,0)along(1400,500,0)"/></QrcInfos>'
      );
      expect(qrc !== null).assertTrue();
      if (qrc !== null) {
        const line = sungLines(qrc.lines)[0];
        expect(line.text).assertEqual('sing along');
        expect(line.words.length).assertEqual(2);
      }

      const plain = parseProvider('first line\nsecond line');
      expect(plain !== null).assertTrue();
      if (plain !== null) {
        const ttml = writeTtml(plain.lines);
        expect(ttml).assertContain('itunes:timing="None"');
        expect(ttml.indexOf('begin=') < 0).assertTrue();
      }
    });

    it('parsePaxSenixTimedKeepsWordAndSyllableTiming', 0, () => {
      const words = parsePaxSenixTimed(
        '{"type":"Word","content":[' +
        '{"timestamp":1000,"text":[{"text":"sing","timestamp":1000},{"text":"along","timestamp":1400}]},' +
        '{"timestamp":2200,"text":[{"text":"again","timestamp":2200}]}]}'
      );
      expect(words !== null).assertTrue();
      if (words !== null) {
        const first = sungLines(words)[0];
        expect(first.text).assertEqual('sing along');
        expect(first.words[1].startMs).assertEqual(1400);
        expect(first.words[1].endMs).assertEqual(2200);
      }

      const syllables = parsePaxSenixTimed(
        '{"type":"Syllable","content":[{"timestamp":31498,"endtime":32529,"text":[' +
        '{"text":"long","timestamp":31498,"endtime":31839,"part":false},' +
        '{"text":"e","timestamp":31839,"endtime":31996,"part":true},' +
        '{"text":"nough","timestamp":31996,"endtime":32529,"part":false}]}]}'
      );
      expect(syllables !== null).assertTrue();
      if (syllables !== null) {
        const line = sungLines(syllables)[0];
        expect(line.text).assertEqual('long enough');
        expect(wordTexts(line.words)).assertEqual('long|enough');
        expect(line.words[0].endMs).assertEqual(31839);
        expect(syllableKey(line.words[1])).assertEqual('31839,31996,0,1;31996,32529,1,6');
      }
    });

    it('withBackgroundVocalsSplitsTrailingBracket', 0, () => {
      const lines = withBackgroundVocals(parseLrc("[00:01.00]I'm foolishly patient (Foolishly patient)"));
      expect(lines[0].text).assertEqual("I'm foolishly patient");
      const backing = lines[0].background;
      expect(backing !== null).assertTrue();
      if (backing !== null) {
        expect(backing.text).assertEqual('(Foolishly patient)');
      }
    });

    it('stripKugouCreditsAndInstrumentalNotice', 0, () => {
      let lrc = '[00:00.00]作词: Someone\n';
      for (let i = 1; i <= 31; i++) {
        const sec = i < 10 ? `0${i}` : `${i}`;
        lrc += `[00:${sec}.00]line ${i}\n`;
      }
      lrc += '[03:00.00]作曲: Other';
      const stripped = stripKugouCredits(lrc);
      expect(stripped.indexOf('作词') < 0).assertTrue();
      expect(stripped.indexOf('作曲') < 0).assertTrue();
      expect(stripped.indexOf('[00:01.00]line 1') >= 0).assertTrue();
      expect(stripped.indexOf('[00:31.00]line 31') >= 0).assertTrue();
      expect(isKugouInstrumentalNotice('[00:01.00]纯音乐，请欣赏')).assertEqual(true);
      expect(isKugouInstrumentalNotice('[00:01.00]hello')).assertEqual(false);
    });
  });
}
