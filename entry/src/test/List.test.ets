import localUnitTest from './LocalUnit.test';
import lyricsParserTest from './LyricsParser.test';

export default function testsuite() {
  localUnitTest();
  lyricsParserTest();
}