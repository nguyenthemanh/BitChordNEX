import { bundleManager, common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { BusinessError, deviceInfo, settings } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { avSession } from '@kit.AVSessionKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { connection, http } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { webview } from '@kit.ArkWeb';
import { NowPlaying, PlaybackCommands, PlaybackSession } from '../core/playbacksession';
import { AppVisibility } from '../core/appvisibility';
import { PlayStore, StoredPlay } from '../core/playstore';
import {
  AccountChannel,
  artworkUrlAt,
  BrowseHeader,
  BrowseType,
  HomeShelf,
  ShelfLayout,
  AudioSource,
  Innertube,
  InnertubeParser,
  MoodGenre,
  MoodGenreSection,
  SearchResult,
  ShelfItem,
  Song,
} from '../core/innertubeapi';
import { isGap, lyricCueMs, LyricLine, LyricWord } from '../core/lyricsmodel';
import { lookupLyrics, LyricsTrack } from '../core/lyricsproviders';
import { extensionAudioUrl, jioAudioUrl } from '../core/jiosaavn';
import { languageFromTag, phrase } from '../core/applang';

const BG: string = '#0B0B0D';
const CARD: string = '#18181B';
const TEXT: string = '#F4F4F5';
const MUTED: string = '#A1A1AA';
const ACCENT: string = '#FF2A3C';
const LOGIN_URL: string = 'https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&prompt=select_account&continue=https%3A%2F%2Fmusic.youtube.com%2F';

function sizedArt(url: string | null, px: number): string {
  const sized = artworkUrlAt(url, px);
  return sized !== null ? sized : '';
}

function clock(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  const secText = seconds < 10 ? `0${seconds}` : `${seconds}`;
  return `${minutes}:${secText}`;
}

class LoginBridge {
  onSignedIn: (cookie: string) => void = (_cookie: string): void => {
  };
}

class OutputRoute {
  id: number = 0;
  name: string = '';
  selected: boolean = false;
}

class PipeChoice {
  label: string = '';
  selected: boolean = false;
}

@Component
struct GoogleLogin {
  bridge: LoginBridge = new LoginBridge();
  private controller: webview.WebviewController = new webview.WebviewController();

  build() {
    Web({ src: LOGIN_URL, controller: this.controller })
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .layoutWeight(1)
      .width('100%')
      .onPageEnd(() => {
        this.capture();
      })
  }

  private capture(): void {
    let url = '';
    try {
      url = this.controller.getUrl();
    } catch (_e) {
      return;
    }
    if (!url.startsWith('https://music.youtube.com')) {
      return;
    }
    let cookie = '';
    try {
      cookie = webview.WebCookieManager.fetchCookieSync('https://music.youtube.com');
    } catch (_e) {
      return;
    }
    if (cookie.indexOf('SAPISID=') < 0 && cookie.indexOf('__Secure-3PAPISID=') < 0) {
      return;
    }
    this.bridge.onSignedIn(cookie);
  }
}

function displayCredit(subtitle: string): string {
  const parts = subtitle.split('•');
  const kept: Array<string> = [];
  for (let i = 0; i < parts.length; i++) {
    const piece = parts[i].trim();
    if (piece.length === 0) {
      continue;
    }
    if (/\b(views|plays|lượt xem|lượt nghe)\b/i.test(piece) || /^\d+:\d{2}/.test(piece)) {
      continue;
    }
    kept.push(piece);
  }
  return kept.length > 0 ? kept.join(' • ') : subtitle;
}

function creditArtist(subtitle: string): string {
  const shown = displayCredit(subtitle);
  const first = shown.split('•')[0].trim();
  return first.length > 0 ? first : shown;
}

function songFromShelf(item: ShelfItem): Song | null {
  if (item.videoId === null || item.videoId.length === 0) {
    return null;
  }
  return new Song(item.videoId, item.title, creditArtist(item.subtitle), item.thumbnailUrl, {
    isVideo: item.isVideo
  });
}

@Entry
@Component
struct Index {
  @State tab: number = 0;
  @State screen: string = 'tabs';
  @State screenUnderPlayer: string = 'tabs';

  @State homeLoading: boolean = true;
  @State homeError: string = '';
  @State shelves: Array<HomeShelf> = [];

  @State exploreLoading: boolean = false;
  @State exploreError: string = '';
  @State exploreShelves: Array<HomeShelf> = [];
  @State moods: Array<MoodGenreSection> = [];
  private exploreLoaded: boolean = false;
  private browseKey: string = '';
  private browseParams: string | null = null;

  @State query: string = '';
  @State searchKind: string = 'all';
  private liveToken: number = 0;
  @State searchLoading: boolean = false;
  @State searchError: string = '';
  @State results: Array<SearchResult> = [];

  @State browseTitle: string = '';
  @State browseSubtitle: string = '';
  @State browseArt: string = '';
  @State browseLoading: boolean = false;
  @State browseError: string = '';
  @State browseSongs: Array<Song> = [];
  @State browseShelves: Array<HomeShelf> = [];

  @State queue: Array<Song> = [];
  @State queueIndex: number = 0;
  @State hasTrack: boolean = false;
  @State playing: boolean = false;
  @State trackTitle: string = '';
  @State trackArtist: string = '';
  @State trackArt: string = '';
  @State trackVideoId: string = '';
  @State positionMs: number = 0;
  @State durationMs: number = 0;
  @State playError: string = '';
  @State lyricLines: Array<LyricLine> = [];
  @State lyricIndex: number = -1;
  @State lyricStatus: string = '';
  private scrubbing: boolean = false;
  private playToken: number = 0;
  private audioSources: AudioSource[] = [];
  private audioSourceIndex: number = 0;
  private wantSound: boolean = true;
  private audioFd: number = -1;
  private lastFault: string = '';
  private surfaceCtl: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private silenceMs: number = -1;
  private silenceSkips: number = 0;
  private mixQuiet: number = -1;
  private loudnessDb: number = 0;
  private loudnessPeak: number = 0.18;
  private loudnessStamp: number = 0;
  private loudnessGainLive: boolean = false;
  private lyricFetchedDuration: number = -1;
  private lyricRetry: boolean = false;
  private fadeGain: number = 1;
  private fadeAdvanced: boolean = false;
  private nextPlayer: media.AVPlayer | null = null;
  private nextFd: number = -1;
  private nextPath: string = '';
  private nextReady: boolean = false;
  private nextLoading: boolean = false;
  private nextStarted: boolean = false;
  private plannedNext: number = -1;
  private mixCut: number = -1;
  private audioId: string = '';
  private playingPath: string = '';
  private eqHolding: boolean = false;
  private webParked: boolean = false;
  private eqPage: number = 0;
  private eqInjected: number = 0;
  private eqFd: number = -1;
  private audioWeb: webview.WebviewController = new webview.WebviewController();
  private audioWebReady: boolean = false;
  private webUrl: string = '';
  private webList: string[] = [];
  private webToken: number = 0;
  private webPollBusy: boolean = false;
  private webPage: number = 0;
  private webInjected: number = 0;
  private effectRetry: boolean = false;
  private player: media.AVPlayer | null = null;
  private mediaSession: PlaybackSession = new PlaybackSession();
  @State favorite: boolean = false;
  @State repeatMode: number = 0;
  @State shuffle: boolean = false;
  @State speed: number = 1;
  @State wifiQuality: string = 'auto';
  @State cellQuality: string = 'auto';
  @State sleepChoice: number = 0;
  @State playerPane: string = 'queue';
  @State playVolume: number = 1;
  @State autoOn: boolean = true;
  @State suggestions: Array<string> = [];
  @State signedIn: boolean = false;
  @State accountHandle: string = '';
  @State accountPhoto: string = '';
  @State accountChannels: Array<AccountChannel> = [];
  @State playerDrag: number = 0;
  @State effectOn: boolean = true;
  @State settingsQuery: string = '';
  @State fullArt: boolean = false;
  @State syncedOn: boolean = true;
  @State statsOn: boolean = false;
  @State loudnessOn: boolean = true;
  @State musicOnly: boolean = false;
  @State uiDark: boolean = true;
  @State genreText: string = '';
  @State trackStat: string = '';
  @State playSource: string = 'YouTube Music';
  @State mixPerf: string = 'balanced';
  @State eqOn: boolean = false;
  @State eqMode: string = 'dynamic';
  @State toneX: number = 0;
  @State toneY: number = 0;
  @State eqWidth: string = 'broad';
  @State contentRegion: string = '';
  @State outsideLyric: boolean = true;
  @State lyricFree: boolean = false;
  @State eqPreset: string = 'Flat';
  @State eqBands: Array<number> = [0, 0, 0, 0, 0, 0, 0];
  @State crossfade: number = 0;
  @State automix: boolean = false;
  @State skipSilence: boolean = false;
  @State spatialOn: boolean = false;
  @State hideVolume: boolean = false;
  @State hideStatus: boolean = false;
  @State hidePlayed: boolean = false;
  @State smartAlign: boolean = true;
  @State lastfm: boolean = true;
  @State themeMode: string = 'dark';
  @State langMode: string = 'system';
  @State lang: string = 'vi';
  @State downloadQuality: string = 'auto';
  @State wifiOnly: boolean = true;
  @State cacheLimit: number = 512;
  private sessionReady: boolean = false;
  @State libraryKind: string = 'songs';
  @State librarySongs: Array<Song> = [];
  @State libraryItems: Array<ShelfItem> = [];
  @State libraryLoading: boolean = false;
  @State libraryError: string = '';
  @State outputName: string = '';
  @State outputDetail: string = '44.1 kHz · 2 ch';
  @State outputRoutes: Array<OutputRoute> = [];
  @State pipeChoices: Array<PipeChoice> = [];
  @State outputPane: string = 'devices';
  private outputDescs: Array<audio.AudioDeviceDescriptor> = [];
  private accountCookie: string = '';
  private loginBridge: LoginBridge = new LoginBridge();
  private sleepDeadline: number = 0;
  private stopAfterTrack: boolean = false;
  private suggestToken: number = 0;
  private ticker: number = -1;
  private lyricScroller: Scroller = new Scroller();
  @State sheet: string = '';
  @State recentGrid: boolean = false;
  @State recentSongs: Array<Song> = [];
  @State menuTitle: string = '';
  @State menuArtist: string = '';
  @State menuArt: string = '';
  @State menuVideoId: string = '';
  @State menuBrowseId: string = '';
  @State notice: string = '';
  @State appBuild: string = '1.9.1';
  @State jioOn: boolean = true;
  @State extensionUrls: string = '';
  @State webdavUrl: string = '';
  @State webdavUser: string = '';
  @State webdavPass: string = '';
  @State webdavState: string = '';
  @State shareUri: string = '';
  @State draftUrl: string = '';
  @State draftUser: string = '';
  @State draftPass: string = '';
  @State partyCode: string = '';

  aboutToAppear(): void {
    AppVisibility.listener = (): void => {
      this.onAppVisibility();
    };
    this.readAppBuild();
    this.applyLanguage();
    this.refreshOutput();
    this.loginBridge.onSignedIn = (cookie: string): void => {
      this.finishLogin(cookie);
    };
    this.restoreStore().then(() => {
      this.loadHome();
    });
    this.ticker = setInterval(() => {
      this.tick();
    }, 400);
  }

  aboutToDisappear(): void {
    AppVisibility.listener = null;
    if (this.ticker >= 0) {
      clearInterval(this.ticker);
    }
    this.releasePlayer();
    this.mediaSession.release();
  }

  build() {
    if (this.lang === 'en') {
      this.rootUi()
    } else if (this.lang === 'zh') {
      this.rootUi()
    } else if (this.lang === 'ja') {
      this.rootUi()
    } else {
      this.rootUi()
    }
  }

  @Builder
  rootUi() {
    Stack() {
      Stack({ alignContent: Alignment.TopStart }) {
        this.playSurface()
      }
      .width(8)
      .height(8)
      .clip(true)
      .hitTestBehavior(HitTestMode.None)

      Web({ src: 'about:blank', controller: this.audioWeb })
        .width(16)
        .height(16)
        .opacity(0.02)
        .hitTestBehavior(HitTestMode.None)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .mediaPlayGestureAccess(false)
        .fileAccess(false)
        .onlineImageAccess(false)
        .onInterceptRequest((event) => {
          return this.eqFile(event);
        })
        .onControllerAttached(() => {
          this.audioWebReady = true;
          this.launchWebAudio();
        })
        .onPageEnd(() => {
          if (this.eqPage > 0 && this.eqInjected !== this.eqPage) {
            this.eqInjected = this.eqPage;
            this.pushEqGraph(true);
            return;
          }
          this.injectWebSources();
        })
      Column() {
        if (this.screen === 'login') {
          this.loginBody()
        } else if (this.screen === 'browse') {
          this.browseBody()
        } else if (this.screen === 'sources') {
          this.sourcesBody()
        } else if (this.screen === 'eq') {
          this.eqBody()
        } else if (this.screen === 'settings') {
          this.settingsBody()
        } else if (this.tab === 0) {
          this.homeBody()
        } else if (this.tab === 1) {
          this.exploreBody()
        } else if (this.tab === 2) {
          this.libraryBody()
        } else {
          this.searchBody()
        }

        if (this.screen !== 'player' && this.screen !== 'login') {
          Column() {
            if (this.hasTrack && this.screen !== 'settings' && this.screen !== 'eq' && this.screen !== 'sources') {
              this.miniPlayer()
            }
            this.tabBar()
          }
          .width('100%')
          .padding({ left: 10, right: 10, bottom: 8 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.page())

      if (this.screen === 'player') {
        this.playerBody()
      }
      if (this.sheet.length > 0) {
        this.sheetLayer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.page())
  }

  @Builder
  homeBody() {
    Column() {
      this.homeHeader()
      if (this.homeLoading) {
        LoadingProgress().width(36).height(36).color(ACCENT).margin({ top: 48 })
      } else if (this.homeError.length > 0) {
        Text(this.shown(this.homeError)).fontColor(this.muted()).fontSize(15).margin({ top: 32, left: 24, right: 24 })
        Button(this.t('reload')).margin({ top: 16 }).backgroundColor(ACCENT).onClick(() => {
          this.loadHome();
        })
      } else {
        Scroll() {
          Column() {
            if (this.recentSongs.length > 0) {
              this.recentHome()
            }
            ForEach(this.shelves, (shelf: HomeShelf, shelfIndex: number) => {
              if (!this.duplicateRecent(shelf.title)) {
                this.shelfBlock(shelf, shelfIndex)
              }
            }, (shelf: HomeShelf, shelfIndex: number) => `${shelfIndex}-${shelf.title}`)
          }
          .width('100%')
          .padding({ bottom: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  exploreBody() {
    Column() {
      this.topTitle(this.t('tab_explore'))
      if (this.exploreLoading) {
        LoadingProgress().width(36).height(36).color(ACCENT).margin({ top: 48 })
      } else if (this.exploreError.length > 0) {
        Text(this.shown(this.exploreError)).fontColor(this.muted()).fontSize(15).margin({ top: 32, left: 24, right: 24 })
        Button(this.t('reload')).margin({ top: 16 }).backgroundColor(ACCENT).onClick(() => {
          this.exploreLoaded = false;
          this.loadExplore();
        })
      } else {
        Scroll() {
          Column() {
            ForEach(this.exploreShelves, (shelf: HomeShelf, shelfIndex: number) => {
              this.shelfBlock(shelf, shelfIndex)
            }, (shelf: HomeShelf, shelfIndex: number) => `e-${shelfIndex}-${shelf.title}`)
            ForEach(this.moods, (section: MoodGenreSection, sectionIndex: number) => {
              Text(section.title)
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.ink())
                .width('100%')
                .padding({ left: 16, right: 16, top: 18, bottom: 10 })
              Scroll() {
                Row({ space: 12 }) {
                  ForEach(section.items, (item: MoodGenre, itemIndex: number) => {
                    Column() {
                      if (item.thumbnailUrl !== null && item.thumbnailUrl.length > 0) {
                        Image(sizedArt(item.thumbnailUrl, 320))
                          .width(148)
                          .height(148)
                          .borderRadius(12)
                          .objectFit(ImageFit.Cover)
                      } else {
                        Column().width(148).height(148).borderRadius(12).backgroundColor(this.card())
                      }
                      Text(item.title)
                        .fontSize(13)
                        .fontColor(this.ink())
                        .maxLines(2)
                        .width(148)
                        .margin({ top: 8 })
                    }
                    .onClick(() => {
                      this.openBrowse(item.browseId, item.params, item.title);
                    })
                  }, (item: MoodGenre, itemIndex: number) => `${sectionIndex}-${itemIndex}-${item.browseId}`)
                }
                .padding({ left: 16, right: 16 })
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
            }, (section: MoodGenreSection, sectionIndex: number) => `m-${sectionIndex}-${section.title}`)
          }
          .width('100%')
          .padding({ bottom: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  searchBody() {
    Column() {
      Row() {
        Column().width(40)
        Text(this.t('search'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.ink())
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        this.accountBadge(36)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Row() {
        SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(16).fontColor(['#8E8E93']).margin({ left: 12, right: 8 })
        TextInput({ text: this.query, placeholder: this.t('search') })
          .layoutWeight(1)
          .height(36)
          .backgroundColor(Color.Transparent)
          .placeholderColor('#8E8E93')
          .fontColor(this.ink())
          .padding({ left: 0 })
          .onChange((value: string) => {
            this.query = value;
            this.scheduleSuggest(value);
            this.scheduleLiveSearch(value);
          })
          .onSubmit(() => {
            this.runSearch();
          })
        if (this.query.length > 0) {
          Text('×')
            .fontSize(18)
            .fontColor('#8E8E93')
            .width(32)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.query = '';
              this.results = [];
              this.suggestions = [];
              this.liveToken += 1;
            })
        }
      }
      .width('92%')
      .height(40)
      .borderRadius(12)
      .backgroundColor('#4D1C1C1E')
      .backdropBlur(24)
      .border({ width: 0.5, color: '#33FFFFFF' })

      Scroll() {
        Row() {
          this.searchChip(this.t('chip_all'), 'all')
          this.searchChip(this.t('chip_songs'), 'song')
          this.searchChip(this.t('chip_videos'), 'video')
          this.searchChip(this.t('chip_albums'), 'album')
          this.searchChip(this.t('chip_artists'), 'artist')
        }
        .padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: 10 })

      if (this.suggestions.length > 0 && this.results.length === 0 && !this.searchLoading) {
        List() {
          ForEach(this.suggestions, (hint: string, index: number) => {
            ListItem() {
              Text(hint)
                .fontSize(16)
                .fontColor(this.ink())
                .width('100%')
                .padding({ left: 20, right: 20, top: 12, bottom: 12 })
                .onClick(() => {
                  this.query = hint;
                  this.suggestions = [];
                  this.runSearch();
                })
            }
          }, (hint: string, index: number) => `sg-${index}-${hint}`)
        }
        .layoutWeight(1)
        .width('100%')
      } else if (this.searchLoading && this.results.length === 0) {
        LoadingProgress().width(36).height(36).color(ACCENT).margin({ top: 24 })
      } else if (this.searchError.length > 0 && this.results.length === 0) {
        Text(this.searchError).fontColor(this.muted()).fontSize(15).margin({ top: 24 })
      } else {
        List() {
          if (this.kindOn('song')) {
            this.searchSection(this.t('chip_songs'), 'song')
          }
          if (this.kindOn('video')) {
            this.searchSection(this.t('chip_videos'), 'video')
          }
          if (this.kindOn('album')) {
            this.searchSection(this.t('chip_albums'), 'album')
          }
          if (this.kindOn('artist')) {
            this.searchSection(this.t('chip_artists'), 'artist')
          }
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  searchChip(label: string, kind: string) {
    Text(label)
      .fontSize(14)
      .fontColor(this.searchKind === kind ? Color.Black : TEXT)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .margin({ right: 8 })
      .borderRadius(16)
      .backgroundColor(this.searchKind === kind ? Color.White : '#33FFFFFF')
      .backdropBlur(16)
      .border({ width: 0.5, color: this.searchKind === kind ? '#00000000' : '#2EFFFFFF' })
      .onClick(() => {
        this.searchKind = kind;
      })
  }

  @Builder
  searchSection(title: string, kind: string) {
    if (this.searchRows(kind).length > 0) {
      ListItem() {
        Text(title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.ink()).width('100%').padding({ left: 16, top: 14, bottom: 6 })
      }
      ForEach(this.searchRows(kind), (row: SearchResult, index: number) => {
        ListItem() {
          this.resultRow(row)
        }
      }, (row: SearchResult, index: number) => `${kind}-${index}-${row.kind}`)
    }
  }

  @Builder
  resultRow(row: SearchResult) {
    Row() {
      if (row.song !== null) {
        this.artBox(sizedArt(row.song.thumbnailUrl, 160), 48)
        Column() {
          Text(row.song.title)
            .fontSize(16)
            .fontColor(this.playingThis(row.song.videoId) ? ACCENT : TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(row.song.artist.length > 0 ? row.song.artist : this.t('chip_songs'))
            .fontSize(13)
            .fontColor('#8E8E93')
            .maxLines(1)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 })
        .onClick(() => {
            const song = row.song;
            if (song !== null) {
              this.playSongs([song], 0);
            }
        })
        if (row.song.durationText !== null && row.song.durationText.length > 0) {
          Text(row.song.durationText).fontSize(13).fontColor('#8E8E93').margin({ right: 8 })
        }
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(18)
          .fontColor(['#8E8E93'])
          .width(28)
          .onClick(() => {
            const song = row.song;
            if (song !== null) {
              this.openSongMenu(song);
            }
          })
      } else if (row.item !== null) {
        this.artBox(sizedArt(row.item.thumbnailUrl, 160), 48)
        Column() {
          Text(row.item.title).fontSize(16).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(row.item.subtitle.length > 0 ? displayCredit(row.item.subtitle) : this.browseKindLabel(row.item.type))
            .fontSize(13)
            .fontColor('#8E8E93')
            .maxLines(1)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 })
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(18)
          .fontColor(['#8E8E93'])
          .width(28)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 7, bottom: 7 })
    .onClick(() => {
      if (row.item !== null && row.song === null) {
        this.openBrowse(row.item.browseId, null, row.item.title);
      }
    })
  }

  @Builder
  browseBody() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(28)
          .fontColor(this.ink())
          .width(40)
          .onClick(() => {
            this.screen = 'tabs';
          })
        Text(this.browseTitle)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
          .maxLines(1)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 16, top: 8 })

      if (this.browseLoading) {
        LoadingProgress().width(36).height(36).color(ACCENT).margin({ top: 48 })
      } else if (this.browseError.length > 0) {
        Text(this.shown(this.browseError)).fontColor(this.muted()).fontSize(15).margin({ top: 32, left: 24, right: 24 })
      } else {
        List() {
          if (this.browseArt.length > 0 || this.browseSubtitle.length > 0) {
            ListItem() {
              Column() {
                if (this.browseArt.length > 0) {
                  Image(this.browseArt).width(180).height(180).borderRadius(12).objectFit(ImageFit.Cover)
                }
                if (this.browseSubtitle.length > 0) {
                  Text(this.browseSubtitle).fontSize(13).fontColor(this.muted()).margin({ top: 10 }).textAlign(TextAlign.Center)
                }
                if (this.browseSongs.length > 0) {
                  Button(this.t('play_all'))
                    .margin({ top: 14 })
                    .backgroundColor(ACCENT)
                    .onClick(() => {
                      this.playSongs(this.browseSongs, 0);
                    })
                }
              }
              .width('100%')
              .padding({ top: 12, bottom: 8 })
            }
          }
          ForEach(this.browseSongs, (song: Song, index: number) => {
            ListItem() {
              Row() {
                Text(`${index + 1}`).width(28).fontSize(13).fontColor(this.muted())
                this.artBox(sizedArt(song.thumbnailUrl, 160), 46)
                Column() {
                  Text(song.title).fontSize(15).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(song.artist).fontSize(12).fontColor(this.muted()).maxLines(1).margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .margin({ left: 10 })
                if (song.durationText !== null) {
                  Text(song.durationText).fontSize(12).fontColor(this.muted())
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 7, bottom: 7 })
              .onClick(() => {
                this.playSongs(this.browseSongs, index);
              })
            }
          }, (song: Song, index: number) => `${song.videoId}-${index}`)
          ForEach(this.browseShelves, (shelf: HomeShelf, shelfIndex: number) => {
            ListItem() {
              this.shelfBlock(shelf, shelfIndex)
            }
          }, (shelf: HomeShelf, shelfIndex: number) => `bs-${shelfIndex}-${shelf.title}`)
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  shelfBlock(shelf: HomeShelf, shelfIndex: number) {
    Column() {
      Row() {
        Text(shelf.title)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
          .layoutWeight(1)
        if (shelfIndex === 0 && this.recentSongs.length === 0 && this.tab === 0 && this.screen === 'tabs') {
          SymbolGlyph(this.recentGrid ? $r('sys.symbol.book') : $r('sys.symbol.square_grid_2x2'))
            .fontSize(20)
            .fontColor([this.muted()])
            .onClick(() => {
              this.recentGrid = !this.recentGrid;
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 10 })

      if (shelf.layout === 'LIST' && !(this.recentGrid && shelfIndex === 0 && this.tab === 0 && this.screen === 'tabs')) {
        Column() {
          ForEach(this.keptItems(shelf.items), (item: ShelfItem, itemIndex: number) => {
            Row() {
              this.artBox(sizedArt(item.thumbnailUrl, 160), 52)
              Column() {
                Text(item.title).fontSize(16).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(displayCredit(item.subtitle)).fontSize(13).fontColor(this.muted()).maxLines(1).margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => {
                this.playShelfItem(shelf, item);
              })
              SymbolGlyph($r('sys.symbol.ellipsis_circle'))
                .fontSize(20)
                .fontColor([this.muted()])
                .onClick(() => {
                  this.openItemMenu(item);
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          }, (item: ShelfItem, itemIndex: number) => `l-${shelfIndex}-${itemIndex}`)
        }
      } else {
        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.keptItems(shelf.items), (item: ShelfItem, itemIndex: number) => {
              Column() {
                this.artBox(sizedArt(item.thumbnailUrl, 320), 148)
                Text(item.title)
                  .fontSize(13)
                  .fontColor(this.ink())
                  .maxLines(2)
                  .width(148)
                  .height(36)
                  .margin({ top: 8 })
                Text(displayCredit(item.subtitle))
                  .fontSize(12)
                  .fontColor(this.muted())
                  .maxLines(1)
                  .width(148)
              }
              .alignItems(HorizontalAlign.Start)
              .onClick(() => {
                this.playShelfItem(shelf, item);
              })
            }, (item: ShelfItem, itemIndex: number) => `c-${shelfIndex}-${itemIndex}`)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  artBox(url: string, size: number) {
    if (url.length > 0) {
      Image(url).width(size).height(size).borderRadius(8).objectFit(ImageFit.Cover).backgroundColor(this.card())
    } else {
      Column().width(size).height(size).borderRadius(8).backgroundColor(this.card())
    }
  }

  @Builder
  recentHome() {
    Column() {
      Row() {
        Text(this.t('recent'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
          .layoutWeight(1)
        SymbolGlyph(this.recentGrid ? $r('sys.symbol.book') : $r('sys.symbol.square_grid_2x2'))
          .fontSize(20)
          .fontColor([this.muted()])
          .onClick(() => {
            this.recentGrid = !this.recentGrid;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      if (this.recentGrid) {
        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.recentSongs, (song: Song, index: number) => {
              Column() {
                this.artBox(sizedArt(song.thumbnailUrl, 320), 148)
                Text(song.title)
                  .fontSize(13)
                  .fontColor(this.ink())
                  .maxLines(2)
                  .width(148)
                  .margin({ top: 8 })
                Text(song.artist)
                  .fontSize(12)
                  .fontColor(this.muted())
                  .maxLines(1)
                  .width(148)
              }
              .alignItems(HorizontalAlign.Start)
              .onClick(() => {
                this.playSongs(this.recentSongs, index);
              })
            }, (song: Song, index: number) => `rg-${song.videoId}-${index}`)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      } else {
        Column() {
          ForEach(this.recentSongs, (song: Song, index: number) => {
            Row() {
              this.artBox(sizedArt(song.thumbnailUrl, 160), 56)
              Column() {
                Text(song.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(song.artist).fontSize(13).fontColor(this.muted()).maxLines(1).margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => {
                this.playSongs(this.recentSongs, index);
              })
              SymbolGlyph($r('sys.symbol.ellipsis_circle'))
                .fontSize(20)
                .fontColor([this.muted()])
                .onClick(() => {
                  this.openSongMenu(song);
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          }, (song: Song, index: number) => `rl-${song.videoId}-${index}`)
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  homeHeader() {
    Row() {
      Text(this.t('listen_now'))
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.ink())
        .layoutWeight(1)
      this.accountBadge(40)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 4 })
  }

  @Builder
  topTitle(title: string) {
    Text(title)
      .fontSize(28)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.ink())
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  miniPlayer() {
    Row() {
      this.artBox(this.trackArt, 42)
      Column() {
        Text(this.trackTitle).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.playError.length > 0 ? this.shown(this.playError) : this.trackArtist)
          .fontSize(12)
          .fontColor(this.playError.length > 0 ? ACCENT : MUTED)
          .maxLines(1)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      .onClick(() => {
        this.openFullPlayer();
      })
      SymbolGlyph(this.soundOn() ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
        .fontSize(22)
        .fontColor([this.ink()])
        .margin({ right: 14 })
        .onClick(() => {
          this.togglePlay();
        })
      SymbolGlyph($r('sys.symbol.forward_end_fill'))
        .fontSize(20)
        .fontColor([this.ink()])
        .onClick(() => {
          this.skip(1);
        })
    }
    .width('100%')
    .height(64)
    .padding({ left: 8, right: 14 })
    .margin({ bottom: 6 })
    .borderRadius(22)
    .backgroundColor('#661C1C1E')
    .backdropBlur(32)
    .border({ width: 0.6, color: '#3DFFFFFF' })
    .shadow({ radius: 18, color: '#66000000', offsetY: 8 })
  }

  @Builder
  tabBar() {
    Row() {
      this.tabItem(this.t('tab_home'), 0)
      this.tabItem(this.t('tab_explore'), 1)
      this.tabItem(this.t('tab_library'), 2)
      this.tabItem(this.t('tab_search'), 3)
    }
    .width('100%')
    .height(64)
    .borderRadius(32)
    .backgroundColor('#592A2A2E')
    .backdropBlur(36)
    .border({ width: 0.6, color: '#3DFFFFFF' })
    .shadow({ radius: 20, color: '#66000000', offsetY: 6 })
    .padding({ left: 6, right: 6 })
  }

  @Builder
  tabGlyph(index: number) {
    if (index === 0) {
      SymbolGlyph($r('sys.symbol.house_fill')).fontSize(20).fontColor([this.tab === index ? Color.White : MUTED])
    } else if (index === 1) {
      SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(20).fontColor([this.tab === index ? Color.White : MUTED])
    } else if (index === 2) {
      SymbolGlyph($r('sys.symbol.book')).fontSize(20).fontColor([this.tab === index ? Color.White : MUTED])
    } else {
      SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(20).fontColor([this.tab === index ? Color.White : MUTED])
    }
  }

  @Builder
  tabItem(label: string, index: number) {
    Column() {
      this.tabGlyph(index)
      Text(label)
        .fontSize(11)
        .fontWeight(this.tab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.tab === index ? Color.White : MUTED)
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .height(52)
    .justifyContent(FlexAlign.Center)
    .borderRadius(26)
    .backgroundColor(this.tab === index ? '#FF2D55' : Color.Transparent)
    .onClick(() => {
      this.tab = index;
      this.screen = 'tabs';
      this.sheet = '';
      if (index === 1 && !this.exploreLoaded) {
        this.loadExplore();
      }
      if (index === 2 && this.signedIn) {
        this.loadLibrary();
      }
    })
  }

  @Builder
  libraryChip(label: string, kind: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.libraryKind === kind ? Color.White : MUTED)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .borderRadius(16)
      .backgroundColor(this.libraryKind === kind ? '#FF3D5A' : '#1C1C1F')
      .margin({ right: 8 })
      .onClick(() => {
        this.libraryKind = kind;
        this.loadLibrary();
      })
  }

  @Builder
  loginBody() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor([this.ink()])
          .width(40)
          .onClick(() => {
            this.screen = 'tabs';
          })
        Text(this.t('login'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 8, right: 16, top: 8 })
      Text(this.t('login_note'))
        .fontSize(13)
        .fontColor(this.muted())
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      GoogleLogin({ bridge: this.loginBridge })
        .layoutWeight(1)
        .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  libraryBody() {
    Column() {
      this.topTitle(this.t('tab_library'))
      if (this.signedIn) {
        Row() {
          this.libraryChip(this.t('lib_songs'), 'songs')
          this.libraryChip(this.t('lib_playlists'), 'playlists')
          this.libraryChip(this.t('lib_albums'), 'albums')
          this.libraryChip(this.t('lib_history'), 'history')
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 8 })
        if (this.libraryLoading) {
          LoadingProgress().width(36).height(36).color(ACCENT).margin({ top: 24 })
        } else if (this.libraryError.length > 0) {
          Text(this.shown(this.libraryError)).fontSize(14).fontColor(this.muted()).margin({ left: 20, right: 20, top: 12 })
        } else if (this.librarySongs.length > 0) {
          List() {
            ForEach(this.librarySongs, (song: Song, index: number) => {
              ListItem() {
                Row() {
                  this.artBox(sizedArt(song.thumbnailUrl, 160), 52)
                  Column() {
                    Text(song.title).fontSize(16).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(song.artist).fontSize(13).fontColor(this.muted()).maxLines(1).margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  .margin({ left: 12 })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                .onClick(() => {
                  this.playSongs(this.librarySongs, index);
                })
              }
            }, (song: Song, index: number) => `ys-${song.videoId}-${index}`)
          }
          .layoutWeight(1)
          .width('100%')
        } else if (this.libraryItems.length > 0) {
          List() {
            ForEach(this.libraryItems, (item: ShelfItem, index: number) => {
              ListItem() {
                Row() {
                  this.artBox(sizedArt(item.thumbnailUrl, 160), 52)
                  Column() {
                    Text(item.title).fontSize(16).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(displayCredit(item.subtitle)).fontSize(13).fontColor(this.muted()).maxLines(1).margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  .margin({ left: 12 })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                .onClick(() => {
                  if (item.browseId !== null && item.browseId.length > 0) {
                    this.openBrowse(item.browseId, null, item.title);
                  }
                })
              }
            }, (item: ShelfItem, index: number) => `yi-${index}-${item.title}`)
          }
          .layoutWeight(1)
          .width('100%')
        } else {
          Text(this.t('empty_item')).fontSize(14).fontColor(this.muted()).margin({ left: 20, top: 12 })
        }
      } else if (this.recentSongs.length === 0) {
          Text(this.t('library_empty'))
          .fontSize(14)
          .fontColor(this.muted())
          .margin({ left: 20, right: 20, top: 12 })
      } else {
        Text(this.t('recent'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
          .width('100%')
          .padding({ left: 16, top: 8, bottom: 8 })
        List() {
          ForEach(this.recentSongs, (song: Song, index: number) => {
            ListItem() {
              Row() {
                this.artBox(sizedArt(song.thumbnailUrl, 160), 52)
                Column() {
                  Text(song.title).fontSize(16).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(song.artist).fontSize(13).fontColor(this.muted()).maxLines(1).margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .margin({ left: 12 })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .onClick(() => {
                this.playSongs(this.recentSongs, index);
              })
            }
          }, (song: Song, index: number) => `lib-${song.videoId}-${index}`)
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  eqBody() {
    Column() {
      Row() {
        Column() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor(['#F4F4F5'])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor('#2C2C2E')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.screen = 'settings';
        })
        Text(this.t('equalizer'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F4F4F5')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Column().width(36).height(36)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })

      Scroll() {
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.waveform')).fontSize(18).fontColor(['#F4F4F5']).width(28)
            Text(this.t('equalizer')).fontSize(16).fontColor('#F4F4F5').layoutWeight(1).margin({ left: 8 })
            Toggle({ type: ToggleType.Switch, isOn: this.eqOn })
              .selectedColor('#FF375F')
              .switchPointColor(Color.White)
              .onChange((on: boolean) => {
                this.eqOn = on;
                this.persistStore();
                this.applyEq();
              })
          }
          .width('100%')
          .padding(14)
          .borderRadius(16)
          .backgroundColor('#1C1C1E')

          Text(this.t('equalizer_sub'))
            .fontSize(13)
            .fontColor('#8E8E93')
            .width('100%')
            .margin({ top: 8, bottom: 16 })

          Row() {
            Text(this.t('eq_dynamic'))
              .fontSize(15)
              .fontColor(this.eqMode === 'dynamic' ? '#F4F4F5' : '#8E8E93')
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(36)
              .borderRadius(10)
              .backgroundColor(this.eqMode === 'dynamic' ? '#3A3A3C' : Color.Transparent)
              .onClick(() => {
                this.eqMode = 'dynamic';
                this.persistStore();
                this.applyEq();
              })
            Text(this.t('eq_manual'))
              .fontSize(15)
              .fontColor(this.eqMode === 'manual' ? '#F4F4F5' : '#8E8E93')
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(36)
              .borderRadius(10)
              .backgroundColor(this.eqMode === 'manual' ? '#3A3A3C' : Color.Transparent)
              .onClick(() => {
                this.eqMode = 'manual';
                this.persistStore();
                this.applyEq();
              })
          }
          .width('100%')
          .padding(4)
          .borderRadius(12)
          .backgroundColor('#1C1C1E')
          .opacity(this.eqOn ? 1 : 0.4)

          Column() {
            if (this.eqMode === 'dynamic') {
              this.eqDynamic()
            } else {
              this.eqManual()
            }
          }
          .width('100%')
          .opacity(this.eqOn ? 1 : 0.35)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor('#000000')
  }

  @Builder
  eqDynamic() {
    Column() {
      Text(this.t('eq_tone'))
        .fontSize(12)
        .fontColor('#8E8E93')
        .width('100%')
        .margin({ top: 18, bottom: 8 })
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          ForEach(this.dotIndex(), (row: number) => {
            Row() {
              ForEach(this.dotIndex(), (col: number) => {
                Column().width(4).height(4).borderRadius(2).backgroundColor('#5C5C60')
              }, (col: number) => `dot-${row}-${col}`)
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceEvenly)
          }, (row: number) => `dot-row-${row}`)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.SpaceEvenly)
        Column()
          .width(34)
          .height(34)
          .borderRadius(17)
          .backgroundColor('#2C2C2E')
          .border({ width: 2, color: '#AEAEB2' })
          .position({ x: this.knobX(), y: this.knobY() })
      }
      .width(320)
      .height(230)
      .borderRadius(18)
      .backgroundColor('#1C1C1E')
      .clip(true)
      .onTouch((event: TouchEvent) => {
        if (event.touches.length > 0) {
          this.setTone(event.touches[0].x, event.touches[0].y, event.type === TouchType.Up);
        } else if (event.type === TouchType.Up) {
          this.persistStore();
        }
      })
      Row() {
        Text('≈').fontSize(16).fontColor('#8E8E93')
        Text(`${Math.round(this.toneX)}`).fontSize(15).fontColor('#C7C7CC').margin({ left: 8 })
        Blank().layoutWeight(1)
        SymbolGlyph($r('sys.symbol.waveform')).fontSize(14).fontColor(['#8E8E93'])
        Text(`${Math.round(this.toneY)}`).fontSize(15).fontColor('#C7C7CC').margin({ left: 8 })
      }
      .width('70%')
      .margin({ top: 12 })
      this.eqWidthRow(this.t('eq_broad'), 'broad')
      this.eqWidthRow(this.t('eq_focused'), 'focused')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  eqWidthRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(16).fontColor('#F4F4F5').layoutWeight(1)
      if (this.eqWidth === value) {
        Text('✓').fontSize(18).fontColor('#FF375F')
      }
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .border({ width: { bottom: 0.5 }, color: '#2C2C2E' })
    .onClick(() => {
      this.eqWidth = value;
      this.persistStore();
      this.applyEq();
    })
  }

  @Builder
  eqManual() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.speaker_wave_2')).fontSize(16).fontColor(['#F4F4F5']).margin({ right: 8 })
        Text(this.t('eq_preset')).fontSize(16).fontColor('#F4F4F5').layoutWeight(1)
        Text(this.eqPreset.length > 0 ? this.eqPreset : this.t('eq_custom')).fontSize(15).fontColor('#8E8E93')
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor(['#8E8E93']).margin({ left: 4 })
      }
      .width('100%')
      .padding(14)
      .margin({ top: 16 })
      .borderRadius(16)
      .backgroundColor('#1C1C1E')
      .onClick(() => {
        this.sheet = 'eqpreset';
      })
      Text(this.t('eq_bands'))
        .fontSize(12)
        .fontColor('#8E8E93')
        .width('100%')
        .margin({ top: 18, bottom: 8 })
      Column() {
        Row() {
          ForEach(this.eqBands, (gain: number, index: number) => {
            Column() {
              Text(`${Math.round(gain)}`).fontSize(12).fontColor('#C7C7CC').height(18)
              Slider({ value: gain, min: -12, max: 12, step: 1, direction: Axis.Vertical })
                .width(28)
                .height(150)
                .blockColor(Color.White)
                .trackColor('#3A3A3C')
                .selectedColor('#8E8E93')
                .onChange((value: number) => {
                  this.setBand(index, value);
                })
              Text(this.bandHz(index)).fontSize(11).fontColor('#8E8E93').margin({ top: 6 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Center)
          }, (gain: number, index: number) => `eq-band-${index}`)
        }
        .width('100%')
        Text(this.t('eq_reset'))
          .fontSize(16)
          .fontColor('#FF375F')
          .margin({ top: 8, bottom: 4 })
          .onClick(() => {
            this.eqBands = [0, 0, 0, 0, 0, 0, 0];
            this.eqPreset = 'Flat';
            this.persistStore();
            this.applyEq();
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 12, bottom: 8 })
      .borderRadius(18)
      .backgroundColor('#1C1C1E')
      Text(this.t('eq_note'))
        .fontSize(13)
        .fontColor('#8E8E93')
        .width('100%')
        .margin({ top: 10 })
    }
    .width('100%')
  }

  @Builder
  eqPresetSheet() {
    Column() {
      Text(this.t('eq_preset'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F4F4F5')
        .width('100%')
        .margin({ bottom: 8 })
      ForEach(this.presetNames(), (name: string) => {
        Row() {
          Text(name).fontSize(16).fontColor('#F4F4F5').layoutWeight(1)
          if (this.eqPreset === name) {
            Text('✓').fontSize(18).fontColor('#FF375F')
          }
        }
        .width('100%')
        .height(44)
        .onClick(() => {
          this.choosePreset(name);
        })
      }, (name: string) => `preset-${name}`)
    }
    .width('100%')
  }

  @Builder
  settingsBody() {
    Column() {
      Row() {
        Column() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(18)
            .fontColor([this.ink()])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor('#2C2C2E')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.screen = 'tabs';
        })
      }
      .width('100%')
      .padding({ left: 16, top: 8 })
      Text(this.t('settings'))
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.ink())
        .width('100%')
        .padding({ left: 20, top: 8, bottom: 12 })
      Row() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(16)
          .fontColor([this.muted()])
          .margin({ left: 12, right: 8 })
        TextInput({ text: this.settingsQuery, placeholder: this.t('search_settings') })
          .layoutWeight(1)
          .height(36)
          .backgroundColor(Color.Transparent)
          .placeholderColor('#8E8E93')
          .fontColor(this.ink())
          .padding({ left: 0, right: 12 })
          .onChange((value: string) => {
            this.settingsQuery = value;
          })
      }
      .width('92%')
      .height(40)
      .margin({ bottom: 8 })
      .borderRadius(12)
      .backgroundColor(this.card())
      Scroll() {
        Column() {
          Column() {
            this.setLink($r('sys.symbol.person'), this.t('account_integrations'), this.signedIn ? this.t('signed_in') : this.t('signed_out'), '', '', () => {
              this.sheet = 'account';
            })
            this.setLink($r('sys.symbol.person'), this.t('listen_together'), this.t('listen_together_sub'), '', '', () => {
              this.sheet = 'party';
            })
          }
          .width('92%')
          .borderRadius(16)
          .backgroundColor(this.card())
          .clip(true)

          this.setHeading(this.t('quality'))
          Column() {
            this.setLink($r('sys.symbol.play_circle'), this.t('sources'), this.t('sources_sub'), '', '', () => {
              this.screen = 'sources';
            })
            this.setLink($r('sys.symbol.wifi'), this.t('on_wifi'), '', this.qualityLabel(this.wifiQuality), this.onCell() ? '' : this.t('in_use'), () => {
              this.wifiQuality = this.wifiQuality === 'auto' ? 'saver' : 'auto';
              this.persistStore();
              if (!this.onCell()) {
                this.replayCurrent();
              }
            })
            this.setLink($r('sys.symbol.wifi'), this.t('on_cell'), '', this.qualityLabel(this.cellQuality), this.onCell() ? this.t('in_use') : '', () => {
              this.cellQuality = this.cellQuality === 'auto' ? 'saver' : 'auto';
              this.persistStore();
              if (this.onCell()) {
                this.replayCurrent();
              }
            })
            this.setSwitch($r('sys.symbol.speaker_wave_2'), this.t('dolby'), this.t('dolby_sub'), this.effectOn, (on: boolean) => {
              this.effectOn = on;
              this.applyEffect();
              this.persistStore();
            })
          }
          .width('92%')
          .borderRadius(16)
          .backgroundColor(this.card())
          .clip(true)

          this.setHeading(this.t('downloads'))
          Column() {
            this.setLink($r('sys.symbol.arrow_down_circle'), this.t('download_quality'), this.downloadQuality === 'auto' ? this.t('download_hi') : this.t('download_lo'), this.qualityLabel(this.downloadQuality), '', () => {
              this.downloadQuality = this.downloadQuality === 'auto' ? 'saver' : 'auto';
              this.persistStore();
            })
            this.setSwitch($r('sys.symbol.wifi'), this.t('wifi_only'), this.t('wifi_only_sub'), this.wifiOnly, (on: boolean) => {
              this.wifiOnly = on;
              this.persistStore();
            }, this.wifiOnly && this.onCell() ? this.t('blocked') : '')
          }
          .width('92%')
          .borderRadius(16)
          .backgroundColor(this.card())
          .clip(true)

          this.setHeading(this.t('playback'))
          Column() {
            this.setSwitch($r('sys.symbol.play_circle'), this.t('music_only'), this.t('music_only_sub'), this.musicOnly, (on: boolean) => {
              this.musicOnly = on;
              this.persistStore();
              if (on && this.hasTrack && this.looksLikeVideo(this.currentSong())) {
                this.replayCurrent();
              }
            })
            this.setSwitch($r('sys.symbol.speaker_wave_2'), this.t('loudness'), this.t('loudness_sub'), this.loudnessOn, (on: boolean) => {
              this.loudnessOn = on;
              this.loudnessDb = 0;
              this.pushLoudness(0);
              this.pushVolume(this.player);
              this.persistStore();
            })
            this.setLink($r('sys.symbol.waveform'), this.t('crossfade'), this.t('crossfade_sub'), this.crossfade <= 0 ? this.t('off') : `${this.crossfade}s`, '', () => {
              this.crossfade = this.crossfade <= 0 ? 4 : 0;
              this.persistStore();
              if (this.fadeMs() > 0) {
                this.queuePrefetch();
              }
            })
            if (this.settingsVisible(this.t('crossfade'), 'Crossfade')) {
              Slider({ value: this.crossfade, min: 0, max: 12, step: 1 })
                .width('88%')
                .margin({ bottom: 8 })
                .blockColor(Color.White)
                .trackColor('#3A3A3C')
                .selectedColor('#8E8E93')
                .onChange((value: number) => {
                  this.crossfade = value;
                  this.persistStore();
                  if (this.fadeMs() > 0) {
                    this.queuePrefetch();
                  }
                })
            }
            this.setSwitch($r('sys.symbol.waveform'), this.t('automix'), this.t('automix_sub'), this.automix, (on: boolean) => {
              this.automix = on;
              this.persistStore();
              if (on) {
                this.queuePrefetch();
              }
            })
            this.setLink($r('sys.symbol.gearshape'), this.t('automix_perf'), '', this.mixLabel(), '', () => {
              this.cycleMix();
            })
            this.setSwitch($r('sys.symbol.speaker_slash'), this.t('skip_silence'), this.t('skip_silence_sub'), this.skipSilence, (on: boolean) => {
              this.skipSilence = on;
              this.persistStore();
            })
            this.setSwitch($r('sys.symbol.dot_radiowaves_left_and_right'), this.t('spatial'), this.t('spatial_sub'), this.spatialOn, (on: boolean) => {
              this.spatialOn = on;
              this.applyEq();
              this.noteSpatial();
              this.persistStore();
            })
            this.setLink($r('sys.symbol.gearshape'), this.t('equalizer'), this.t('equalizer_sub'), this.eqOn ? (this.eqMode === 'manual' ? (this.eqPreset.length > 0 ? this.eqPreset : this.t('eq_custom')) : this.t('eq_dynamic')) : this.t('off'), '', () => {
              this.screen = 'eq';
            })
          }
          .width('92%')
          .borderRadius(16)
          .backgroundColor(this.card())
          .clip(true)

          this.setHeading(this.t('appearance'))
          Column() {
            if (this.settingsVisible(this.t('theme'), this.t('theme_system'))) {
              Row() {
                SymbolGlyph($r('sys.symbol.circle'))
                  .fontSize(18)
                  .fontColor([this.ink()])
                  .margin({ right: 12 })
                Text(this.t('theme')).fontSize(16).fontColor(this.ink()).layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 8 })
              Row() {
                this.themeChip(this.t('theme_system'), 'system')
                this.themeChip(this.t('theme_light'), 'light')
                this.themeChip(this.t('theme_dark'), 'dark')
              }
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 14 })
            }
            this.setSwitch($r('sys.symbol.square_grid_2x2'), this.t('full_art'), this.t('full_art_sub'), this.fullArt, (on: boolean) => {
              this.fullArt = on;
              this.persistStore();
            })
            this.setSwitch($r('sys.symbol.list_bullet'), this.t('synced_lyrics'), this.t('synced_lyrics_sub'), this.syncedOn, (on: boolean) => {
              this.syncedOn = on;
              this.persistStore();
            })
            this.setSwitch($r('sys.symbol.book'), this.t('outside_lyric'), this.t('outside_lyric_sub'), this.outsideLyric, (on: boolean) => {
              this.outsideLyric = on;
              this.persistStore();
              this.syncSession(true);
            })
            Text(this.t('lyric_place'))
              .fontSize(13)
              .fontColor('#8E8E93')
              .width('100%')
              .padding({ left: 16, right: 16, top: 4 })
              .opacity(this.outsideLyric ? 1 : 0.35)
            Row() {
              this.lyricPlaceChip(this.t('lyric_island'), false)
              this.lyricPlaceChip(this.t('lyric_free'), true)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 14 })
            .opacity(this.outsideLyric ? 1 : 0.35)
            .enabled(this.outsideLyric)
            .hitTestBehavior(this.outsideLyric ? HitTestMode.Default : HitTestMode.None)
          }
          .width('92%')
          .borderRadius(16)
          .backgroundColor(this.card())
          .clip(true)

          Column() {
            this.setSwitch($r('sys.symbol.eye_slash'), this.t('hide_played'), this.t('hide_played_sub'), this.hidePlayed, (on: boolean) => {
              this.hidePlayed = on;
              this.persistStore();
            })
            this.setSwitch($r('sys.symbol.speaker_slash'), this.t('hide_volume'), this.t('hide_volume_sub'), this.hideVolume, (on: boolean) => {
              this.hideVolume = on;
              this.persistStore();
            })
            this.setSwitch($r('sys.symbol.eye_slash'), this.t('hide_status'), this.t('hide_status_sub'), this.hideStatus, (on: boolean) => {
              this.hideStatus = on;
              this.persistStore();
            })
          }
          .width('92%')
          .margin({ top: 18 })
          .borderRadius(16)
          .backgroundColor(this.card())
          .clip(true)

          this.setHeading(this.t('language'))
          Column() {
            this.languageRow()
          }
          .width('92%')
          .borderRadius(16)
          .backgroundColor(this.card())
          .clip(true)

          this.setHeading(this.t('advanced'))
          Column() {
            this.setSwitch($r('sys.symbol.waveform'), this.t('smart_align'), this.t('smart_align_sub'), this.smartAlign, (on: boolean) => {
              this.smartAlign = on;
              this.persistStore();
            })
            this.setSwitch($r('sys.symbol.book'), this.t('stats'), this.t('stats_sub'), this.statsOn, (on: boolean) => {
              this.statsOn = on;
              this.persistStore();
            })
          }
          .width('92%')
          .borderRadius(16)
          .backgroundColor(this.card())
          .clip(true)

          this.setHeading(this.t('cache'))
          Column() {
            if (this.settingsVisible(this.t('cache_limit'), this.t('cache'))) {
              Text(this.t('cache_limit'))
                .fontSize(16)
                .fontColor(this.ink())
                .width('100%')
                .padding({ left: 16, right: 16, top: 14 })
              Text(`${this.cacheLimit} MB`)
                .fontSize(13)
                .fontColor(this.muted())
                .width('100%')
                .padding({ left: 16, right: 16, top: 2 })
              Slider({ value: this.cacheLimit, min: 128, max: 2048, step: 64 })
                .width('88%')
                .margin({ top: 4, bottom: 8 })
                .blockColor(Color.White)
                .trackColor('#3A3A3C')
                .selectedColor('#8E8E93')
                .onChange((value: number) => {
                  this.cacheLimit = value;
                  this.persistStore();
                  this.trimDownloads();
                })
            }
            this.setLink($r('sys.symbol.trash'), this.t('clear_audio'), this.t('clear_audio_sub'), '', '', () => {
              this.clearSongCache();
            })
            this.setLink($r('sys.symbol.trash'), this.t('clear_images'), this.t('clear_images_sub'), '', '', () => {
              this.clearImageCache();
            })
          }
          .width('92%')
          .borderRadius(16)
          .backgroundColor(this.card())
          .clip(true)

          this.setHeading(this.t('your_data'))
          Column() {
            this.setLink($r('sys.symbol.book'), this.t('replay'), this.t('replay_sub'), '', '', () => {
              this.tab = 2;
              this.screen = 'tabs';
              this.libraryKind = 'replay';
              this.loadLibrary();
            })
            this.setSwitch($r('sys.symbol.bookmark'), this.t('genres'), this.t('genres_sub'), this.lastfm, (on: boolean) => {
              this.lastfm = on;
              this.persistStore();
              if (on) {
                this.loadGenre(this.trackArtist, this.playToken);
              } else {
                this.genreText = '';
              }
            })
            this.setLink($r('sys.symbol.folder'), this.t('export_data'), this.t('export_data_sub'), '', '', () => {
              this.exportData();
            })
            this.setLink($r('sys.symbol.arrow_down_circle'), this.t('import_data'), this.t('import_data_sub'), '', '', () => {
              this.importData();
            })
          }
          .width('92%')
          .borderRadius(16)
          .backgroundColor(this.card())
          .clip(true)

          if (this.notice.length > 0) {
            Text(this.shown(this.notice)).fontSize(13).fontColor(ACCENT).margin({ left: 20, right: 20, top: 12 })
          }
          Text() {
            Span(this.t('author_name'))
              .fontSize(13)
              .fontColor('#4C9FFF')
              .decoration({ type: TextDecorationType.Underline, color: '#4C9FFF' })
            Span(` ${this.t('author_rest')}`)
              .fontSize(13)
              .fontColor('#8E8E93')
          }
          .textAlign(TextAlign.Center)
          .width('88%')
          .margin({ top: 28, bottom: 4 })
          .onClick(() => {
            this.openAuthor();
          })
          Text(`${this.t('version_beta')} (${this.t('version_build')} ${this.appBuild})`)
            .fontSize(12)
            .fontColor('#8E8E93')
            .textAlign(TextAlign.Center)
            .width('88%')
            .margin({ bottom: 8 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ bottom: 96 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  setHeading(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor('#8E8E93')
      .width('92%')
      .padding({ left: 16, top: 22, bottom: 8 })
  }

  @Builder
  lyricPlaceChip(label: string, free: boolean) {
    Text(label)
      .fontSize(14)
      .fontColor(this.lyricFree === free && this.outsideLyric ? '#F4F4F5' : '#8E8E93')
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(36)
      .borderRadius(10)
      .backgroundColor(this.lyricFree === free && this.outsideLyric ? '#3A3A3C' : Color.Transparent)
      .onClick(() => {
        if (!this.outsideLyric || this.lyricFree === free) {
          return;
        }
        this.lyricFree = free;
        this.persistStore();
        this.syncSession(true);
      })
  }

  @Builder
  themeChip(label: string, mode: string) {
    Text(label)
      .fontSize(14)
      .fontColor(this.themeMode === mode ? TEXT : MUTED)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(32)
      .borderRadius(8)
      .backgroundColor(this.themeMode === mode ? '#3A3A3C' : Color.Transparent)
      .onClick(() => {
        this.themeMode = mode;
        this.applyTheme();
        this.persistStore();
      })
  }

  @Builder
  setLink(symbol: Resource, title: string, subtitle: string, value: string, badge: string, action: () => void) {
    if (this.settingsVisible(title, subtitle)) {
      Row() {
        SymbolGlyph(symbol).fontSize(18).fontColor([this.ink()]).width(28)
        Column() {
          Text(title).fontSize(16).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (subtitle.length > 0) {
            Text(subtitle).fontSize(13).fontColor('#8E8E93').margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })
        if (badge.length > 0) {
          Text(badge)
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .backgroundColor('#FF375F')
            .margin({ right: 8 })
        }
        if (value.length > 0) {
          Text(value).fontSize(15).fontColor('#8E8E93').margin({ right: 4 })
        }
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor(['#8E8E93'])
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .onClick(() => {
        action();
      })
    }
  }

  @Builder
  setSwitch(symbol: Resource, title: string, subtitle: string, on: boolean, action: (next: boolean) => void, badge: string = '') {
    if (this.settingsVisible(title, subtitle)) {
      Row() {
        SymbolGlyph(symbol).fontSize(18).fontColor([this.ink()]).width(28)
        Column() {
          Row() {
            Text(title).fontSize(16).fontColor(this.ink()).maxLines(2).layoutWeight(1)
            if (badge.length > 0) {
              Text(badge)
                .fontSize(10)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(4)
                .backgroundColor('#FF375F')
                .margin({ left: 8 })
            }
          }
          .width('100%')
          if (subtitle.length > 0) {
            Text(subtitle).fontSize(13).fontColor('#8E8E93').margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10, right: 8 })
        Toggle({ type: ToggleType.Switch, isOn: on })
          .selectedColor('#FF375F')
          .switchPointColor(Color.White)
          .onChange((next: boolean) => {
            action(next);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    }
  }

  @Builder
  sourcesBody() {
    Column() {
      Row() {
        Column() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(18)
            .fontColor([this.ink()])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor('#2C2C2E')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.screen = 'settings';
        })
      }
      .width('100%')
      .padding({ left: 16, top: 6 })

      Text(this.t('sources'))
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.ink())
        .width('100%')
        .padding({ left: 20, top: 10, bottom: 16 })

      Scroll() {
        Column() {
          Text(this.t('sources_order'))
            .fontSize(12)
            .fontColor('#8E8E93')
            .letterSpacing(0.4)
            .width('100%')
            .padding({ left: 4, right: 4, bottom: 8 })

          Column() {
            this.jioSourceRow()
            this.youtubeSourceRow()
            ForEach(this.extensionList(), (url: string, index: number) => {
              this.extensionSourceRow(url, index + 3)
            }, (url: string) => url)
            this.addExtensionRow()
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 8 })
          .borderRadius(22)
          .backgroundColor(this.card())
          .clip(true)
          .alignItems(HorizontalAlign.Start)

          Text(this.t('sources_fallback'))
            .fontSize(15)
            .fontColor('#8E8E93')
            .lineHeight(21)
            .width('100%')
            .padding({ left: 4, right: 4, top: 16 })

          Text(this.t('sources_lossless'))
            .fontSize(15)
            .fontColor('#8E8E93')
            .lineHeight(21)
            .width('100%')
            .padding({ left: 4, right: 4, top: 18 })

          Text('WEBDAV')
            .fontSize(12)
            .fontColor('#8E8E93')
            .letterSpacing(0.6)
            .width('100%')
            .padding({ left: 4, right: 4, top: 26, bottom: 8 })

          this.linkCard($r('sys.symbol.cloud'), 'WebDAV', this.webdavSubtitle(), () => {
            this.draftUrl = this.webdavUrl;
            this.draftUser = this.webdavUser;
            this.draftPass = this.webdavPass;
            this.sheet = 'webdav';
          })

          Text(this.t('webdav_hint'))
            .fontSize(15)
            .fontColor('#8E8E93')
            .lineHeight(21)
            .width('100%')
            .padding({ left: 4, right: 4, top: 12 })

          this.linkCard($r('sys.symbol.folder'), this.t('share_folder'), this.shareSubtitle(), () => {
            this.pickShareFolder();
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  jioSourceRow() {
    Row() {
      Text('1')
        .fontSize(16)
        .fontColor('#8E8E93')
        .width(22)
      Row() {
        Column().width(2).height(8).borderRadius(1).backgroundColor(TEXT)
        Column().width(2).height(14).borderRadius(1).backgroundColor(TEXT).margin({ left: 2 })
        Column().width(2).height(10).borderRadius(1).backgroundColor(TEXT).margin({ left: 2 })
        Column().width(2).height(6).borderRadius(1).backgroundColor(TEXT).margin({ left: 2 })
      }
      .width(28)
      .height(18)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .margin({ left: 4, right: 8 })
      Column() {
        Text('JioSaavn')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.ink())
          .width('100%')
        Text(this.t('jio_risk'))
          .fontSize(13)
          .fontColor('#8E8E93')
          .lineHeight(18)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.jioOn })
        .selectedColor(Color.White)
        .switchPointColor('#1C1C1E')
        .margin({ left: 8 })
        .onChange((on: boolean) => {
          this.jioOn = on;
          this.persistStore();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 12 })
  }

  @Builder
  youtubeSourceRow() {
    Row() {
      Text('2')
        .fontSize(16)
        .fontColor('#8E8E93')
        .width(22)
      SymbolGlyph($r('sys.symbol.play_circle'))
        .fontSize(20)
        .fontColor([this.ink()])
        .width(28)
        .margin({ left: 4, right: 8 })
      Column() {
        Text('YouTube Music')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.ink())
        Text(this.t('yt_line'))
          .fontSize(13)
          .fontColor('#8E8E93')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(this.t('always_on'))
        .fontSize(15)
        .fontColor('#8E8E93')
        .margin({ left: 8 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 12 })
  }

  @Builder
  extensionSourceRow(url: string, order: number) {
    Row() {
      Text(`${order}`)
        .fontSize(16)
        .fontColor('#8E8E93')
        .width(22)
      Text('＋')
        .fontSize(18)
        .fontColor(this.ink())
        .width(28)
        .textAlign(TextAlign.Center)
        .margin({ left: 4, right: 8 })
      Column() {
        Text(this.hostOf(url))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.ink())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.t('ext_line'))
          .fontSize(13)
          .fontColor('#8E8E93')
          .maxLines(2)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(this.t('remove'))
        .fontSize(14)
        .fontColor('#FF375F')
        .onClick(() => {
          this.removeExtension(url);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 12 })
  }

  @Builder
  addExtensionRow() {
    Row() {
      Text('+')
        .fontSize(26)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FF375F')
        .width(28)
        .margin({ left: 22, right: 6 })
      Column() {
        Text(this.t('add_ext'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FF375F')
        Text(this.t('add_ext_sub'))
          .fontSize(13)
          .fontColor('#8E8E93')
          .lineHeight(18)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 6, bottom: 10 })
    .onClick(() => {
      this.draftUrl = '';
      this.sheet = 'extension';
    })
  }

  @Builder
  linkCard(symbol: Resource, title: string, subtitle: string, action: () => void) {
    Row() {
      SymbolGlyph(symbol)
        .fontSize(22)
        .fontColor(['#8E8E93'])
        .width(36)
        .margin({ right: 8 })
      Column() {
        Text(title)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.ink())
        Text(subtitle)
          .fontSize(13)
          .fontColor('#8E8E93')
          .maxLines(2)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor(['#8E8E93'])
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .margin({ top: 8 })
    .borderRadius(22)
    .clip(true)
    .backgroundColor(this.card())
    .onClick(() => {
      action();
    })
  }

  @Builder
  extensionSheet() {
    Column() {
      Text(this.t('add_ext'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.ink())
        .width('100%')
      Text(this.t('add_ext_note'))
        .fontSize(13)
        .fontColor('#8E8E93')
        .width('100%')
        .margin({ top: 6, bottom: 12 })
      TextInput({ text: this.draftUrl, placeholder: 'https://may-chu-cua-ban' })
        .width('100%')
        .height(44)
        .borderRadius(12)
        .backgroundColor(this.card())
        .placeholderColor('#8E8E93')
        .fontColor(this.ink())
        .onChange((value: string) => {
          this.draftUrl = value;
        })
      Button(this.t('add_list'))
        .width('100%')
        .height(44)
        .margin({ top: 14 })
        .backgroundColor('#FF375F')
        .onClick(() => {
          this.addExtension(this.draftUrl);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  webdavSheet() {
    Column() {
      Text('WebDAV')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.ink())
        .width('100%')
      Text(this.t('webdav_hint'))
        .fontSize(13)
        .fontColor('#8E8E93')
        .width('100%')
        .margin({ top: 6, bottom: 12 })
      TextInput({ text: this.draftUrl, placeholder: 'https://may-chu/nhac' })
        .width('100%')
        .height(44)
        .borderRadius(12)
        .backgroundColor(this.card())
        .placeholderColor('#8E8E93')
        .fontColor(this.ink())
        .onChange((value: string) => {
          this.draftUrl = value;
        })
      TextInput({ text: this.draftUser, placeholder: this.t('login_name') })
        .width('100%')
        .height(44)
        .margin({ top: 8 })
        .borderRadius(12)
        .backgroundColor(this.card())
        .placeholderColor('#8E8E93')
        .fontColor(this.ink())
        .onChange((value: string) => {
          this.draftUser = value;
        })
      TextInput({ text: this.draftPass, placeholder: this.t('password') })
        .type(InputType.Password)
        .width('100%')
        .height(44)
        .margin({ top: 8 })
        .borderRadius(12)
        .backgroundColor(this.card())
        .placeholderColor('#8E8E93')
        .fontColor(this.ink())
        .onChange((value: string) => {
          this.draftPass = value;
        })
      Button(this.t('connect'))
        .width('100%')
        .height(44)
        .margin({ top: 14 })
        .backgroundColor('#FF375F')
        .onClick(() => {
          this.connectWebdav();
        })
      if (this.webdavUrl.length > 0) {
        Text(this.t('disconnect'))
          .fontSize(15)
          .fontColor('#FF375F')
          .margin({ top: 14 })
          .onClick(() => {
            this.webdavUrl = '';
            this.webdavUser = '';
            this.webdavPass = '';
            this.webdavState = '';
            this.sheet = '';
            this.persistStore();
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sheetLayer() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => {
          this.sheet = '';
        })
      Column() {
        Column().width(36).height(4).borderRadius(2).backgroundColor('#52525B').margin({ top: 8, bottom: 12 })
        if (this.sheet === 'account') {
          this.accountSheet()
        } else if (this.sheet === 'location') {
          this.locationSheet()
        } else if (this.sheet === 'output') {
          this.outputSheet()
        } else if (this.sheet === 'eqpreset') {
          this.eqPresetSheet()
        } else if (this.sheet === 'party') {
          this.partySheet()
        } else if (this.sheet === 'extension') {
          this.extensionSheet()
        } else if (this.sheet === 'webdav') {
          this.webdavSheet()
        } else {
          this.menuSheet()
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 28 })
      .borderRadius({ topLeft: 28, topRight: 28 })
      .backgroundColor('#B31C1C1E')
      .backdropBlur(48)
      .border({ width: { top: 0.6, left: 0, right: 0, bottom: 0 }, color: '#40FFFFFF' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
  }

  @Builder
  accountBadge(size: number) {
    Column() {
      if (this.accountPhoto.length > 0) {
        Image(this.accountPhoto).width(size).height(size).borderRadius(size / 2).objectFit(ImageFit.Cover)
      } else {
        SymbolGlyph($r('sys.symbol.person')).fontSize(size * 0.45).fontColor([this.ink()])
      }
    }
    .width(size)
    .height(size)
    .borderRadius(size / 2)
    .backgroundColor('#2C2C2E')
    .justifyContent(FlexAlign.Center)
    .clip(true)
    .border({ width: 0.5, color: '#33FFFFFF' })
    .onClick(() => {
      this.openAccount();
    })
  }

  @Builder
  outputSheet() {
    Column() {
      if (this.outputPane === 'pipe') {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(16).fontColor([this.ink()]).margin({ right: 8 })
          Text('Audio Pipeline').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.ink())
        }
        .width('100%')
        .height(44)
        .margin({ bottom: 8 })
        .onClick(() => {
          this.outputPane = 'devices';
        })
        Column() {
          ForEach(this.pipeChoices, (pipe: PipeChoice, index: number) => {
            Row() {
              Text(pipe.label).fontSize(16).fontColor(this.ink()).layoutWeight(1)
              if (pipe.selected) {
                Text('✓').fontSize(18).fontColor('#FF375F')
              }
            }
            .width('100%')
            .height(52)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.pickPipe(index);
            })
          }, (pipe: PipeChoice, index: number) => `pipe-${index}-${pipe.label}`)
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor('#2C2C2E')
        .clip(true)
      } else {
        Text(this.t('audio_output'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ink())
          .width('100%')
          .margin({ bottom: 14 })
        Column() {
          ForEach(this.outputRoutes, (route: OutputRoute, index: number) => {
            Row() {
              Column() {
                Column()
                  .width(12)
                  .height(18)
                  .border({ width: 1.6, color: TEXT })
                  .borderRadius(3)
              }
              .width(36)
              .height(36)
              .borderRadius(18)
              .backgroundColor('#3A3A3C')
              .justifyContent(FlexAlign.Center)
              Column() {
                Text(route.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.ink()).maxLines(1)
                Text(route.selected ? this.t('playing_here') : this.t('pick_device'))
                  .fontSize(13)
                  .fontColor('#8E8E93')
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 12 })
              if (route.selected) {
                Text('✓').fontSize(18).fontColor('#FF375F')
              }
            }
            .width('100%')
            .height(64)
            .padding({ left: 14, right: 14 })
            .onClick(() => {
              this.pickOutput(index);
            })
          }, (route: OutputRoute, index: number) => `route-${route.id}-${index}`)
          Row() {
            SymbolGlyph($r('sys.symbol.speaker_wave_2')).fontSize(16).fontColor(['#8E8E93']).margin({ right: 8 })
            Slider({ value: this.playVolume, min: 0, max: 1, step: 0.05 })
              .layoutWeight(1)
              .blockColor(Color.White)
              .selectedColor('#8E8E93')
              .trackColor('#5C5C60')
              .onChange((value: number) => {
                this.applyVolume(value);
              })
          }
          .width('100%')
          .padding({ left: 14, right: 16, bottom: 12 })
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor('#2C2C2E')
        .clip(true)
        Row() {
          Column() {
            SymbolGlyph($r('sys.symbol.waveform')).fontSize(16).fontColor([this.ink()])
          }
          .width(36)
          .height(36)
          .borderRadius(18)
          .backgroundColor('#3A3A3C')
          .justifyContent(FlexAlign.Center)
          Column() {
            Text('Audio Pipeline').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.ink())
            Text(this.outputDetail).fontSize(13).fontColor('#8E8E93').margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 12 })
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor(['#8E8E93'])
        }
        .width('100%')
        .height(68)
        .padding({ left: 14, right: 14 })
        .margin({ top: 12 })
        .borderRadius(16)
        .backgroundColor('#2C2C2E')
        .onClick(() => {
          this.outputPane = 'pipe';
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  languageMark() {
    Stack() {
      Text('A')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.ink())
        .translate({ x: -6, y: 5 })
      Text('文')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.ink())
        .translate({ x: 7, y: -6 })
    }
    .width(28)
    .height(28)
  }

  @Builder
  languageRow() {
    if (this.settingsVisible(this.t('app_language'), this.langLabel())) {
      Row() {
        this.languageMark()
        Column() {
          Text(this.t('app_language'))
            .fontSize(16)
            .fontColor(this.ink())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.langLabel())
            .fontSize(13)
            .fontColor('#8E8E93')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })
        Text(this.langMark())
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#8E8E93')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .onClick(() => {
        this.cycleLanguage();
      })
    }
  }

  @Builder
  globeMark() {
    Stack() {
      Circle()
        .width(18)
        .height(18)
        .fill(Color.Transparent)
        .stroke(this.ink())
        .strokeWidth(1.5)
      Ellipse()
        .width(8)
        .height(18)
        .fill(Color.Transparent)
        .stroke(this.ink())
        .strokeWidth(1.2)
      Column()
        .width(16)
        .height(1)
        .backgroundColor(this.ink())
    }
    .width(28)
    .height(28)
  }

  @Builder
  locationSheet() {
    Column() {
      Text(this.t('location'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.ink())
        .width('100%')
      Text(this.t('location_sub'))
        .fontSize(13)
        .fontColor('#8E8E93')
        .width('100%')
        .margin({ top: 6, bottom: 8 })
      Scroll() {
        Column() {
          this.regionRow('', this.t('location_auto'))
          ForEach(this.regionRows(), (row: string) => {
            this.regionRow(row.split('|')[0], row.split('|')[1])
          }, (row: string) => `region-${row}`)
        }
        .width('100%')
      }
      .width('100%')
      .height(420)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  regionRow(code: string, name: string) {
    Row() {
      Text(name).fontSize(16).fontColor(this.ink()).layoutWeight(1)
      if (this.contentRegion === code) {
        Text('✓').fontSize(18).fontColor('#FF375F')
      }
    }
    .width('100%')
    .height(44)
    .onClick(() => {
      this.chooseRegion(code);
    })
  }

  @Builder
  accountSheet() {
    Column() {
      Text(this.accountHandle.length > 0 ? this.accountHandle : (this.signedIn ? 'YouTube Music' : this.t('signed_out')))
        .fontSize(15)
        .fontColor('#8E8E93')
        .width('100%')
        .margin({ bottom: 10 })
      if (this.accountChannels.length > 0) {
        ForEach(this.accountChannels, (ch: AccountChannel, index: number) => {
          Row() {
            if (this.channelPhoto(ch).length > 0) {
              Image(this.channelPhoto(ch)).width(48).height(48).borderRadius(24).objectFit(ImageFit.Cover)
            } else {
              Column() {
                SymbolGlyph($r('sys.symbol.person')).fontSize(20).fontColor([this.ink()])
              }
              .width(48)
              .height(48)
              .borderRadius(24)
              .backgroundColor('#3A3A3C')
              .justifyContent(FlexAlign.Center)
            }
            Column() {
              Text(ch.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.channelLine(ch).length > 0 ? this.channelLine(ch) : this.t('no_channel'))
                .fontSize(13)
                .fontColor('#8E8E93')
                .maxLines(1)
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 12 })
            if (ch.activeOnWeb) {
              Text('✓').fontSize(20).fontColor('#FF375F')
            }
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            this.useChannel(index);
          })
        }, (ch: AccountChannel, index: number) => `ac-${index}-${ch.name}`)
      } else if (!this.signedIn) {
        Text(this.t('sign_in_prompt'))
          .fontSize(14)
          .fontColor(this.muted())
          .width('100%')
          .margin({ bottom: 8 })
      }
      this.sheetAction($r('sys.symbol.plus'), this.t('add_account'), () => {
        this.sheet = '';
        this.openLogin();
      })
      this.sheetAction($r('sys.symbol.person'), this.t('manage_account'), () => {
        this.sheet = '';
        this.screen = 'settings';
      })
      if (this.screen === 'settings') {
      Row() {
        this.globeMark()
        Text(this.t('location')).fontSize(16).fontColor(this.ink()).layoutWeight(1).margin({ left: 12 })
          Text(this.regionLabel()).fontSize(15).fontColor('#8E8E93')
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor(['#8E8E93']).margin({ left: 4 })
        }
        .width('100%')
        .height(48)
        .onClick(() => {
          this.sheet = 'location';
        })
      } else {
        this.sheetAction($r('sys.symbol.gearshape'), this.t('settings'), () => {
          this.sheet = '';
          this.screen = 'settings';
        })
      }
      if (this.signedIn) {
        this.sheetAction($r('sys.symbol.person'), this.t('sign_out'), () => {
          this.sheet = '';
          this.signOut();
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  partySheet() {
    Column() {
      Text(this.t('listen_together'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.ink())
        .width('100%')
      Text(this.t('listen_together_sub'))
        .fontSize(13)
        .fontColor(this.muted())
        .width('100%')
        .margin({ top: 6, bottom: 12 })
      Text(this.trackVideoId.length > 0 ? this.trackVideoId : this.t('party_empty'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.ink())
        .width('100%')
        .margin({ bottom: 12 })
      TextInput({ text: this.partyCode, placeholder: this.t('party_code') })
        .width('100%')
        .height(44)
        .borderRadius(12)
        .backgroundColor(this.card())
        .placeholderColor('#8E8E93')
        .fontColor(this.ink())
        .onChange((value: string) => {
          this.partyCode = value.trim();
        })
      Button(this.t('party_play'))
        .width('100%')
        .height(44)
        .margin({ top: 14 })
        .backgroundColor('#FF375F')
        .onClick(() => {
          this.playPartyCode();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  menuSheet() {
    Column() {
      Row() {
        this.artBox(this.menuArt, 48)
        Column() {
          Text(this.menuTitle).fontSize(16).fontColor(this.ink()).maxLines(1)
          Text(this.menuArtist).fontSize(13).fontColor(this.muted()).maxLines(1).margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
        .layoutWeight(1)
      }
      .width('100%')
      .margin({ bottom: 8 })
      this.sheetAction($r('sys.symbol.play_fill'), this.t('play_now'), () => {
        this.playMenuItem(false);
      })
      this.sheetAction($r('sys.symbol.forward_end_fill'), this.t('play_next'), () => {
        this.playMenuItem(true);
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sheetAction(symbol: Resource, label: string, action: () => void) {
    Row() {
      SymbolGlyph(symbol).fontSize(20).fontColor([this.ink()]).width(28)
      Text(label).fontSize(16).fontColor(this.ink()).margin({ left: 12 })
    }
    .width('100%')
    .height(48)
    .onClick(() => {
      action();
    })
  }

  @Builder
  playerBody() {
    Column() {
      Column() {
        Column()
          .width(44)
          .height(5)
          .borderRadius(3)
          .backgroundColor('#C8C8CC')
      }
      .width('100%')
      .height(44)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.closePlayer();
      })
      .gesture(
        PanGesture({ direction: PanDirection.Vertical, distance: 6 })
          .onActionUpdate((event: GestureEvent) => {
            this.playerDrag = event.offsetY > 0 ? event.offsetY : 0;
          })
          .onActionEnd((event: GestureEvent) => {
            if (event.offsetY > 48) {
              this.closePlayer();
            } else {
              this.playerDrag = 0;
            }
          })
      )

      if (this.fullArt) {
        this.artBox(this.trackArt, 280)
      }
      Row() {
        if (!this.fullArt) {
          this.artBox(this.trackArt, 52)
        }
        Column() {
          Text(this.trackTitle).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.trackArtist).fontSize(13).fontColor('#A1A1A6').maxLines(1).margin({ top: 2 })
          if (!this.hideStatus && this.playSource.length > 0) {
            Text(this.playSource).fontSize(12).fontColor('#8E8E93').maxLines(1).margin({ top: 2 })
          }
          if (this.lastfm && this.genreText.length > 0) {
            Text(this.genreText).fontSize(12).fontColor('#C7C7CC').maxLines(1).margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 })
        Text(this.favorite ? '♥' : '♡')
          .fontSize(22)
          .fontColor(this.ink())
          .width(36)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.favorite = !this.favorite;
            this.syncSession(true);
          })
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(22)
          .fontColor([this.ink()])
          .width(36)
          .onClick(() => {
            this.openSongMenu(this.currentSong());
          })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 4, bottom: 8 })
      .gesture(
        PanGesture({ direction: PanDirection.Vertical, distance: 8 })
          .onActionUpdate((event: GestureEvent) => {
            this.playerDrag = event.offsetY > 0 ? event.offsetY : 0;
          })
          .onActionEnd((event: GestureEvent) => {
            if (event.offsetY > 48) {
              this.closePlayer();
            } else {
              this.playerDrag = 0;
            }
          })
      )

      if (this.playerPane === 'words') {
        Text(this.t('lyrics')).fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.ink()).width('100%').padding({ left: 16, top: 18 })
        Text(this.shown(this.lyricStatus)).fontSize(13).fontColor('#8E8E93').width('100%').padding({ left: 16, top: 4, bottom: 8 })
        List({ scroller: this.lyricScroller, space: 14 }) {
          ForEach(this.lyricLines, (line: LyricLine, index: number) => {
            ListItem() {
              if (this.lyricIndex === index && line.words.length > 0) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(line.words, (word: LyricWord, wordIndex: number) => {
                    Text(`${word.text} `)
                      .fontSize(22)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(word.startMs <= this.positionMs ? TEXT : '#8E8E93')
                  }, (word: LyricWord, wordIndex: number) => `${index}-${wordIndex}-${word.startMs}`)
                }
                .width('100%')
                .padding({ left: 16, right: 16 })
              } else {
                Text(isGap(line) ? '♪' : line.text)
                  .fontSize(this.lyricIndex === index ? 22 : 17)
                  .fontWeight(this.lyricIndex === index ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(this.lyricIndex === index ? TEXT : '#8E8E93')
                  .width('100%')
                  .padding({ left: 16, right: 16 })
              }
            }
          }, (line: LyricLine, index: number) => `${index}-${line.timeMs}-${line.text}`)
        }
        .layoutWeight(1)
        .width('100%')
      } else {
        List() {
          ListItem() {
            Text(this.t('queue')).fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.ink()).width('100%').padding({ left: 16, top: 18, bottom: 8 })
          }
          ListItem() {
            Text(this.t('now_playing')).fontSize(13).fontColor('#8E8E93').width('100%').padding({ left: 16, bottom: 6 })
          }
          ListItem() {
            this.playerTrackRow(this.currentSong(), true, this.queueIndex)
          }
          ListItem() {
            Column() {
              Row() {
                Text('∞').fontSize(18).fontColor(this.autoOn ? TEXT : '#8E8E93').width(28)
                Text(this.t('autoplay')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.ink())
              }
              .width('100%')
              Text(this.t('autoplay_sub'))
                .fontSize(13)
                .fontColor('#8E8E93')
                .width('100%')
                .margin({ top: 2, left: 28 })
            }
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 16, right: 16, top: 14, bottom: 8 })
          }
          ForEach(this.upcoming(), (song: Song, index: number) => {
            ListItem() {
              this.playerTrackRow(song, false, this.queueIndex + 1 + index)
            }
          }, (song: Song, index: number) => `up-${song.videoId}-${index}`)
          ListItem() {
            Row() {
              Text('♪').fontSize(16).fontColor(this.ink()).width(28)
              Text(this.t('lyrics')).fontSize(16).fontColor(this.ink()).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor(['#8E8E93'])
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 10 })
            .onClick(() => {
              this.playerPane = 'words';
            })
          }
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }

      if (this.playError.length > 0) {
        Text(this.shown(this.playError)).fontSize(12).fontColor(ACCENT).width('100%').padding({ left: 20, right: 20 }).textAlign(TextAlign.Center)
      }

      Slider({
        value: this.positionMs,
        min: 0,
        max: this.durationMs > 0 ? this.durationMs : 1,
        step: 500,
      })
        .width('92%')
        .blockColor(Color.White)
        .selectedColor(Color.White)
        .trackColor('#5C5C60')
        .onChange((value: number, mode: SliderChangeMode) => {
          this.positionMs = value;
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.scrubbing = true;
          }
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.scrubbing = false;
            this.seekTo(value);
          }
        })
      Row() {
        Text(clock(this.positionMs)).fontSize(12).fontColor('#8E8E93')
        Blank().layoutWeight(1)
        Text(this.remainLabel()).fontSize(12).fontColor('#8E8E93')
      }
      .width('92%')
      if (this.statsOn && this.trackStat.length > 0) {
        Text(this.trackStat)
          .fontSize(12)
          .fontColor('#C7C7CC')
          .width('92%')
          .margin({ top: 4 })
          .textAlign(TextAlign.Center)
      }

      Row() {
        SymbolGlyph($r('sys.symbol.backward_end_fill')).fontSize(30).fontColor([this.ink()]).width(72).onClick(() => {
          this.advance(false, -1);
        })
        SymbolGlyph(this.soundOn() ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(54)
          .fontColor([this.ink()])
          .width(88)
          .onClick(() => {
            this.togglePlay();
          })
        SymbolGlyph($r('sys.symbol.forward_end_fill')).fontSize(30).fontColor([this.ink()]).width(72).onClick(() => {
          this.advance(false, 1);
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ top: 4 })

      if (!this.hideVolume) {
        Row() {
          SymbolGlyph($r('sys.symbol.speaker_slash')).fontSize(14).fontColor(['#8E8E93']).margin({ right: 8 })
          Slider({ value: this.playVolume, min: 0, max: 1, step: 0.05 })
            .layoutWeight(1)
            .blockColor(Color.White)
            .selectedColor('#8E8E93')
            .trackColor('#5C5C60')
            .onChange((value: number) => {
              this.applyVolume(value);
            })
          SymbolGlyph($r('sys.symbol.speaker_wave_2')).fontSize(16).fontColor(['#8E8E93']).margin({ left: 8 })
        }
        .width('92%')
        .margin({ top: 4 })
      }

      Row() {
        Text('♪').fontSize(18).fontColor(this.playerPane === 'words' ? TEXT : '#8E8E93').layoutWeight(1).textAlign(TextAlign.Center).onClick(() => {
          this.playerPane = this.playerPane === 'words' ? 'queue' : 'words';
        })
        SymbolGlyph($r('sys.symbol.shuffle')).fontSize(18).fontColor([this.shuffle ? TEXT : '#8E8E93']).layoutWeight(1).onClick(() => {
          this.shuffle = !this.shuffle;
          this.persistStore();
          this.syncSession(true);
        })
        SymbolGlyph(this.repeatMode === 2 ? $r('sys.symbol.repeat_1') : $r('sys.symbol.repeat'))
          .fontSize(18)
          .fontColor([this.repeatMode === 0 ? '#8E8E93' : TEXT])
          .layoutWeight(1)
          .onClick(() => {
            this.repeatMode = (this.repeatMode + 1) % 3;
            this.persistStore();
            this.syncSession(true);
          })
        Text('∞').fontSize(20).fontColor(this.autoOn ? TEXT : '#8E8E93').layoutWeight(1).textAlign(TextAlign.Center).onClick(() => {
          this.autoOn = !this.autoOn;
        })
        SymbolGlyph($r('sys.symbol.list_bullet')).fontSize(18).fontColor([this.playerPane === 'queue' ? TEXT : '#8E8E93']).layoutWeight(1).onClick(() => {
          this.playerPane = 'queue';
        })
      }
      .width('86%')
      .height(52)
      .margin({ top: 8 })
      .borderRadius(26)
      .backgroundColor('#662C2A28')
      .backdropBlur(24)
      .border({ width: 0.5, color: '#33FFFFFF' })

      Text(this.outputName.length > 0 ? this.outputName : this.deviceTitle())
        .fontSize(13)
        .fontColor('#C7C7CC')
        .margin({ top: 10, bottom: 12 })
        .onClick(() => {
          this.outputPane = 'devices';
          this.refreshOutput();
          this.sheet = 'output';
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#B3161412')
    .backdropBlur(50)
    .translate({ y: this.playerDrag })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  playerTrackRow(song: Song, current: boolean, index: number) {
    Row() {
      if (!current) {
        SymbolGlyph($r('sys.symbol.list_bullet')).fontSize(16).fontColor(['#8E8E93']).width(22).margin({ right: 6 })
      }
      this.artBox(sizedArt(song.thumbnailUrl, 160), 44)
      Column() {
        Text(song.title).fontSize(15).fontColor(this.ink()).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(song.artist).fontSize(12).fontColor('#8E8E93').maxLines(1).margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      .onClick(() => {
        if (!current) {
          this.playAt(index);
        }
      })
      if (current) {
        SymbolGlyph($r('sys.symbol.waveform')).fontSize(16).fontColor([this.ink()]).margin({ right: 10 })
      }
      Text('×').fontSize(22).fontColor('#8E8E93').width(28).textAlign(TextAlign.Center).onClick(() => {
        this.removeQueued(index);
      })
    }
    .width('100%')
    .padding({ left: current ? 16 : 10, right: 12, top: 6, bottom: 6 })
  }

  @Builder
  playSurface() {
    XComponent({
      id: 'bcSurface',
      type: XComponentType.SURFACE,
      controller: this.surfaceCtl
    })
      .width(8)
      .height(8)
      .opacity(0.01)
      .hitTestBehavior(HitTestMode.None)
      .onLoad(() => {
        this.captureSurface();
        this.rebindSurface();
      })
  }

  private captureSurface(): void {
    try {
      const id = this.surfaceCtl.getXComponentSurfaceId();
      if (id.length > 0) {
        this.surfaceId = id;
      }
    } catch (_e) {
    }
  }

  private rebindSurface(): void {
    if (this.player === null || this.surfaceId.length === 0) {
      return;
    }
    try {
      this.player.surfaceId = this.surfaceId;
    } catch (_e) {
    }
  }

  private bindSurface(av: media.AVPlayer): void {
    if (this.surfaceId.length === 0) {
      this.captureSurface();
    }
    if (this.surfaceId.length === 0) {
      return;
    }
    try {
      av.surfaceId = this.surfaceId;
    } catch (_e) {
    }
  }

  private currentSong(): Song {
    if (this.queueIndex >= 0 && this.queueIndex < this.queue.length) {
      return this.queue[this.queueIndex];
    }
    const art = this.trackArt.length > 0 ? this.trackArt : null;
    return new Song(this.trackVideoId, this.trackTitle, this.trackArtist, art);
  }

  private upcoming(): Array<Song> {
    const out: Array<Song> = [];
    if (!this.autoOn) {
      return out;
    }
    for (let i = this.queueIndex + 1; i < this.queue.length; i++) {
      out.push(this.queue[i]);
    }
    return out;
  }

  private remainLabel(): string {
    const left = this.durationMs - this.positionMs;
    return `-${clock(left > 0 ? left : 0)}`;
  }

  private applyVolume(value: number): void {
    this.playVolume = value;
    this.pushVolume(this.player);
  }

  private removeQueued(index: number): void {
    if (index < 0 || index >= this.queue.length) {
      return;
    }
    const next: Array<Song> = [];
    for (let i = 0; i < this.queue.length; i++) {
      if (i !== index) {
        next.push(this.queue[i]);
      }
    }
    if (index === this.queueIndex) {
      this.queue = next;
      const at = index < next.length ? index : next.length - 1;
      if (at >= 0) {
        this.playAt(at);
      }
      return;
    }
    if (index < this.queueIndex) {
      this.queueIndex -= 1;
    }
    this.queue = next;
  }

  @Builder
  queueBody() {
    List() {
      ForEach(this.queue, (song: Song, index: number) => {
        ListItem() {
          Row() {
            this.artBox(sizedArt(song.thumbnailUrl, 160), 46)
            Column() {
              Text(song.title)
                .fontSize(15)
                .fontColor(index === this.queueIndex ? ACCENT : TEXT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(song.artist).fontSize(12).fontColor(this.muted()).maxLines(1).margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 12 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .onClick(() => {
            this.playAt(index);
            this.playerPane = 'now';
          })
        }
      }, (song: Song, index: number) => `q-${song.videoId}-${index}`)
    }
    .layoutWeight(1)
    .width('100%')
  }

  private openFullPlayer(): void {
    this.screenUnderPlayer = this.screen === 'player' ? this.screenUnderPlayer : this.screen;
    this.screen = 'player';
    this.sheet = '';
  }

  private openItemMenu(item: ShelfItem): void {
    this.menuTitle = item.title;
    this.menuArtist = displayCredit(item.subtitle);
    this.menuArt = sizedArt(item.thumbnailUrl, 320);
    this.menuVideoId = item.videoId !== null ? item.videoId : '';
    this.menuBrowseId = item.browseId !== null ? item.browseId : '';
    this.sheet = 'menu';
  }

  private playMenuItem(queueNext: boolean): void {
    this.sheet = '';
    if (this.menuVideoId.length === 0) {
      if (this.menuBrowseId.length > 0) {
        this.openBrowse(this.menuBrowseId, null, this.menuTitle);
      }
      return;
    }
    const song = new Song(this.menuVideoId, this.menuTitle, this.menuArtist, this.menuArt);
    if (!queueNext || !this.hasTrack) {
      this.playSongs([song], 0);
      return;
    }
    const nextQueue: Array<Song> = [];
    for (let i = 0; i < this.queue.length; i++) {
      nextQueue.push(this.queue[i]);
      if (i === this.queueIndex) {
        nextQueue.push(song);
      }
    }
    this.queue = nextQueue;
    this.notice = 'k:queued_next';
  }

  private duplicateRecent(title: string): boolean {
    if (this.recentSongs.length === 0) {
      return false;
    }
    const name = title.toLowerCase();
    return name.indexOf('gần đây') >= 0 || name.indexOf('recent') >= 0 || name.indexOf('listen again') >= 0 || name.indexOf('nghe lại') >= 0;
  }

  private openSongMenu(song: Song): void {
    this.menuTitle = song.title;
    this.menuArtist = song.artist;
    this.menuArt = sizedArt(song.thumbnailUrl, 320);
    this.menuVideoId = song.videoId;
    this.menuBrowseId = '';
    this.sheet = 'menu';
  }

  private sessionFile(): string {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return '';
    }
    return `${(host as common.UIAbilityContext).filesDir}/account.cookie`;
  }

  private writeSession(cookie: string): void {
    const path = this.sessionFile();
    if (path.length === 0) {
      return;
    }
    try {
      if (cookie.length === 0) {
        fileIo.unlinkSync(path);
        return;
      }
      const opened = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(opened.fd, cookie);
      fileIo.closeSync(opened.fd);
    } catch (_e) {
    }
  }

  private readSession(): string {
    const path = this.sessionFile();
    if (path.length === 0) {
      return '';
    }
    try {
      return fileIo.readTextSync(path);
    } catch (_e) {
      return '';
    }
  }

  private applyWebCookies(cookie: string): void {
    const parts = cookie.split(';');
    for (let i = 0; i < parts.length; i++) {
      const piece = parts[i].trim();
      if (piece.indexOf('=') < 0) {
        continue;
      }
      try {
        webview.WebCookieManager.configCookieSync('https://music.youtube.com', piece);
        webview.WebCookieManager.configCookieSync('https://www.youtube.com', piece);
      } catch (_e) {
      }
    }
    try {
      webview.WebCookieManager.saveCookieSync();
    } catch (_e) {
    }
  }

  private rememberSong(song: Song): void {
    const kept: Array<Song> = [song];
    for (let i = 0; i < this.recentSongs.length; i++) {
      if (this.recentSongs[i].videoId !== song.videoId && kept.length < 30) {
        kept.push(this.recentSongs[i]);
      }
    }
    this.recentSongs = kept;
    this.persistStore();
  }

  private loadHome(): void {
    this.homeLoading = true;
    this.homeError = '';
    this.fetchHome();
  }

  private async fetchHome(): Promise<void> {
    try {
      const response = await Innertube.browse('FEmusic_home', null, true);
      const parsed = InnertubeParser.parseHome(response);
      this.shelves = parsed;
      if (parsed.length === 0) {
        this.homeError = 'k:home_empty';
      }
    } catch (e) {
      const detail = e instanceof Error ? e.message : `${e}`;
      hilog.error(0x0000, 'BitChord', 'home %{public}s gl %{public}s', detail.substring(0, 180), Innertube.currentRegion);
      this.homeError = 'k:home_fail';
    }
    this.homeLoading = false;
  }

  private loadExplore(): void {
    this.exploreLoaded = true;
    this.exploreLoading = true;
    this.exploreError = '';
    this.fetchExplore();
  }

  private async fetchExplore(): Promise<void> {
    try {
      const country = Innertube.currentRegion;
      const shelves: Array<HomeShelf> = [];
      const seen: Array<string> = [];
      const addShelves = (list: Array<HomeShelf>): void => {
        for (let i = 0; i < list.length; i++) {
          const key = list[i].title.trim().toLowerCase();
          if (key.length === 0 || seen.includes(key)) {
            continue;
          }
          seen.push(key);
          shelves.push(list[i]);
        }
      };
      try {
        const charts = await Innertube.browse('FEmusic_charts', null, true, country);
        const chartShelves = InnertubeParser.parseHome(charts);
        const trending = await this.countryChartShelves(chartShelves);
        addShelves(trending);
        addShelves(chartShelves);
      } catch (_charts) {
      }
      try {
        const fresh = await Innertube.browse('FEmusic_new_releases', null, true);
        addShelves(InnertubeParser.parseHome(fresh));
      } catch (_fresh) {
      }
      const response = await Innertube.browse('FEmusic_explore', null, true);
      const exploreShelves = InnertubeParser.parseHome(response);
      const regionalExplore: Array<HomeShelf> = [];
      for (let i = 0; i < exploreShelves.length; i++) {
        if (!this.isIpTrendingTitle(exploreShelves[i].title)) {
          regionalExplore.push(exploreShelves[i]);
        }
      }
      addShelves(regionalExplore);
      let moods = InnertubeParser.parseMoodAndGenres(response);
      try {
        const moodPage = await Innertube.browse('FEmusic_moods_and_genres', null, true);
        const more = InnertubeParser.parseMoodAndGenres(moodPage);
        if (more.length > 0) {
          moods = more;
        }
      } catch (_moods) {
      }
      this.exploreShelves = shelves;
      this.moods = moods;
      if (shelves.length === 0 && moods.length === 0) {
        this.exploreError = 'k:explore_bad';
      }
    } catch (_e) {
      this.exploreError = 'k:explore_fail';
      this.exploreLoaded = false;
    }
    this.exploreLoading = false;
  }

  private isIpTrendingTitle(title: string): boolean {
    const key = title.trim().toLowerCase();
    return key === 'thịnh hành' || key === 'trending' || key === 'trending now' ||
      key === '热门' || key === '热门歌曲' || key === '正在流行' || key === 'トレンド';
  }

  private async countryChartShelves(charts: Array<HomeShelf>): Promise<Array<HomeShelf>> {
    const out: Array<HomeShelf> = [];
    const seen: Array<string> = [];
    for (let s = 0; s < charts.length && out.length < 2; s++) {
      const shelf = charts[s];
      for (let i = 0; i < shelf.items.length && out.length < 2; i++) {
        const item = shelf.items[i];
        const id = item.browseId;
        if (id === null || !id.startsWith('VL') || seen.includes(id)) {
          continue;
        }
        seen.push(id);
        try {
          const page = await Innertube.browse(id, null, true);
          const parsed = InnertubeParser.parsePlaylistShelf(page);
          if (parsed === null || parsed.songs.length === 0) {
            continue;
          }
          const songs: Array<ShelfItem> = [];
          const limit = parsed.songs.length < 20 ? parsed.songs.length : 20;
          for (let n = 0; n < limit; n++) {
            const song = parsed.songs[n];
            songs.push(new ShelfItem(song.title, song.artist, song.thumbnailUrl, song.videoId, null, song.isVideo));
          }
          out.push(new HomeShelf(item.title, songs, '', id, null, ShelfLayout.LIST));
        } catch (_playlist) {
        }
      }
    }
    return out;
  }

  private scheduleSuggest(text: string): void {
    this.suggestToken += 1;
    const token = this.suggestToken;
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      this.suggestions = [];
      return;
    }
    setTimeout(() => {
      this.fetchSuggest(trimmed, token);
    }, 280);
  }

  private async fetchSuggest(text: string, token: number): Promise<void> {
    try {
      const response = await Innertube.searchSuggestions(text);
      if (token !== this.suggestToken) {
        return;
      }
      this.suggestions = InnertubeParser.parseSearchSuggestions(response);
    } catch (_e) {
      if (token === this.suggestToken) {
        this.suggestions = [];
      }
    }
  }

  private scheduleLiveSearch(text: string): void {
    this.liveToken += 1;
    const token = this.liveToken;
    const trimmed = text.trim();
    if (trimmed.length < 2) {
      this.results = [];
      this.searchError = '';
      return;
    }
    setTimeout(() => {
      if (token === this.liveToken) {
        this.runSearch();
      }
    }, 350);
  }

  private kindOn(kind: string): boolean {
    return this.searchKind === 'all' || this.searchKind === kind;
  }

  private playingThis(videoId: string): boolean {
    return this.hasTrack && this.trackVideoId === videoId;
  }

  private browseKindLabel(type: BrowseType): string {
    if (type === BrowseType.ARTIST) {
      return this.t('chip_artists');
    }
    if (type === BrowseType.ALBUM) {
      return this.t('chip_albums');
    }
    if (type === BrowseType.PLAYLIST) {
      return 'Playlist';
    }
    return this.t('chip_songs');
  }

  private searchRows(kind: string): Array<SearchResult> {
    const out: Array<SearchResult> = [];
    for (let i = 0; i < this.results.length; i++) {
      const row = this.results[i];
      const song = row.song;
      const item = row.item;
      if (kind === 'song' && song !== null && !song.isVideo) {
        if (this.hidePlayed && this.wasPlayed(song.videoId)) {
          continue;
        }
        out.push(row);
      } else if (kind === 'video' && song !== null && song.isVideo) {
        out.push(row);
      } else if (kind === 'album' && item !== null && item.type === BrowseType.ALBUM) {
        out.push(row);
      } else if (kind === 'artist' && item !== null && item.type === BrowseType.ARTIST) {
        out.push(row);
      }
    }
    return out;
  }

  private runSearch(): void {
    this.suggestions = [];
    const text = this.query.trim();
    if (text.length === 0) {
      return;
    }
    this.searchLoading = true;
    this.searchError = '';
    this.fetchSearch(text);
  }

  private async fetchSearch(text: string): Promise<void> {
    try {
      const response = await Innertube.search(text);
      const page = InnertubeParser.parseSearchPage(response, false);
      this.results = page.rows;
      if (page.rows.length === 0) {
        this.searchError = this.t('no_results');
      }
    } catch (_e) {
      this.searchError = this.t('search_failed');
    }
    this.searchLoading = false;
  }

  private openBrowse(browseId: string, params: string | null, title: string): void {
    this.browseKey = browseId;
    this.browseParams = params;
    this.browseTitle = title;
    this.browseSubtitle = '';
    this.browseArt = '';
    this.browseSongs = [];
    this.browseShelves = [];
    this.browseError = '';
    this.browseLoading = true;
    this.screen = 'browse';
    this.fetchBrowse(browseId, params, title);
  }

  private async fetchBrowse(browseId: string, params: string | null, title: string): Promise<void> {
    try {
      const regional = browseId.indexOf('FEmusic_') === 0;
      const response = await Innertube.browse(browseId, params, regional);
      const header: BrowseHeader | null = InnertubeParser.parseBrowseHeader(response);
      if (header !== null) {
        if (header.title.length > 0) {
          this.browseTitle = header.title;
        }
        this.browseSubtitle = header.subtitle;
        this.browseArt = sizedArt(header.thumbnailUrl, 480);
      }
      const playlist = InnertubeParser.parsePlaylistShelf(response);
      if (playlist !== null && playlist.songs.length > 0) {
        this.browseSongs = playlist.songs;
      }
      if (browseId.startsWith('UC') || this.browseSongs.length === 0) {
        const artist = InnertubeParser.parseArtistPage(response);
        if (artist.songs.length > 0) {
          this.browseSongs = artist.songs;
        }
        if (artist.sections.length > 0) {
          this.browseShelves = artist.sections;
        }
        if (artist.name !== null && artist.name.length > 0 && this.browseTitle === title) {
          this.browseTitle = artist.name;
        }
        if (this.browseArt.length === 0) {
          this.browseArt = sizedArt(artist.thumbnailUrl, 480);
        }
      }
      if (this.browseSongs.length === 0 && this.browseShelves.length === 0) {
        this.browseError = 'k:browse_empty';
      }
    } catch (_e) {
      this.browseError = 'k:browse_fail';
    }
    this.browseLoading = false;
  }

  private openShelfItem(shelf: HomeShelf, index: number): void {
    const item = shelf.items[index];
    const song = songFromShelf(item);
    if (song !== null) {
      const songs: Array<Song> = [];
      let playIndex = 0;
      for (let i = 0; i < shelf.items.length; i++) {
        const next = songFromShelf(shelf.items[i]);
        if (next !== null) {
          if (i === index) {
            playIndex = songs.length;
          }
          songs.push(next);
        }
      }
      this.playSongs(songs, playIndex);
      return;
    }
    if (item.browseId !== null && item.browseId.length > 0) {
      this.openBrowse(item.browseId, null, item.title);
    }
  }

  private playSongs(songs: Array<Song>, index: number): void {
    if (songs.length === 0 || index < 0 || index >= songs.length) {
      return;
    }
    this.queue = songs;
    this.playAt(index);
    this.screenUnderPlayer = this.screen === 'player' ? this.screenUnderPlayer : this.screen;
    this.screen = 'player';
  }

  private playAt(index: number): void {
    if (index < 0 || index >= this.queue.length) {
      return;
    }
    const song = this.showSong(index, true);
    const token = this.playToken;
    this.startAudio(song.videoId, token);
    this.startLyrics(song, token);
    this.loadGenre(this.trackArtist, token);
    this.syncSession(true);
  }

  private showSong(index: number, resetPosition: boolean): Song {
    const song = this.queue[index];
    this.queueIndex = index;
    this.hasTrack = true;
    this.rememberSong(song);
    this.playing = !resetPosition;
    this.trackTitle = song.title;
    this.trackArtist = creditArtist(song.artist);
    this.trackArt = sizedArt(song.thumbnailUrl, 720);
    this.trackVideoId = song.videoId;
    if (resetPosition) {
      this.positionMs = 0;
      const known = song.durationMillis();
      this.durationMs = known > 0 ? known : 0;
    }
    this.playError = '';
    this.wantSound = true;
    this.favorite = false;
    this.lyricLines = [];
    this.lyricIndex = -1;
    this.lyricStatus = 'k:lyric_search';
    this.effectRetry = false;
    if (this.eqHolding || this.eqPage > 0) {
      this.eqHolding = false;
      this.eqPage = 0;
      this.eqInjected = 0;
      if (this.eqFd >= 0) {
        try {
          fileIo.closeSync(this.eqFd);
        } catch (_e) {
        }
        this.eqFd = -1;
      }
    }
    this.silenceMs = -1;
    this.silenceSkips = 0;
    this.mixQuiet = -1;
    this.webParked = false;
    this.fadeGain = 1;
    this.loudnessDb = 0;
    this.loudnessPeak = 0.18;
    this.loudnessStamp = 0;
    this.lyricFetchedDuration = -1;
    this.lyricRetry = false;
    this.fadeAdvanced = false;
    this.mixCut = -1;
    this.plannedNext = -1;
    this.trackStat = '';
    this.genreText = '';
    this.playSource = 'YouTube Music';
    this.playToken += 1;
    return song;
  }

  private async startAudio(videoId: string, token: number): Promise<void> {
    let playId = videoId;
    if (this.musicOnly && this.looksLikeVideo(this.currentSong())) {
      const alt = await this.catalogueAudioId();
      if (token !== this.playToken) {
        return;
      }
      if (alt.length > 0) {
        playId = alt;
        this.playSource = 'YouTube Music';
      }
    }
    this.audioId = playId;
    const saved = this.openSaved(playId);
    if (saved >= 0) {
      this.playSource = this.t('saved_audio');
      this.audioSources = [];
      await this.attachPlayer('', '', token, saved);
      return;
    }
    const muxed = await Innertube.resolveMuxedUrl(playId, this.playbackCap());
    if (token !== this.playToken) {
      return;
    }
    if (muxed.sources.length > 0) {
      this.webUrl = '';
      this.webList = [];
      if (this.audioWebReady) {
        this.audioWeb.runJavaScript('var a=document.getElementById("a");if(a){a.pause();a.removeAttribute("src");}');
      }
      this.audioSources = muxed.sources;
      this.audioSourceIndex = 0;
      this.lastFault = '';
      const first = muxed.sources[0];
      await this.attachPlayer(first.url, first.userAgent, token);
      return;
    }
    const jioTask = this.jioOn ? jioAudioUrl(this.trackTitle, this.trackArtist) : Promise.resolve('');
    const extraTask = this.lookupExtensions();
    const resolved = await Innertube.resolveAudioUrl(videoId, this.bitrateCap());
    const jio = await jioTask;
    const extras = await extraTask;
    if (token !== this.playToken) {
      return;
    }
    const ordered: string[] = [];
    for (let i = 0; i < extras.length; i++) {
      ordered.push(extras[i]);
    }
    if (jio.length > 0) {
      ordered.push(jio);
    }
    if (resolved.sources.length === 0 && ordered.length === 0) {
      this.playError = resolved.detail.length > 0
        ? resolved.detail
        : 'k:play_no_url';
      return;
    }
    this.lastFault = '';
    this.audioSources = resolved.sources;
    this.audioSourceIndex = 0;
    for (let i = resolved.sources.length - 1; i >= 0; i--) {
      ordered.push(resolved.sources[i].url);
    }
    this.webUrl = ordered[0];
    this.webList = ordered;
    this.webToken = token;
    this.launchWebAudio();
  }

  private async lookupExtensions(): Promise<Array<string>> {
    const found: Array<string> = [];
    const list = this.extensionList();
    for (let i = 0; i < list.length; i++) {
      const url = await extensionAudioUrl(list[i], this.trackTitle, this.trackArtist);
      if (url.length > 0) {
        found.push(url);
      }
    }
    return found;
  }

  private jsQuote(value: string): string {
    return value.replace(/\\/g, '\\\\').replace(/'/g, '\\\'');
  }

  private launchWebAudio(): void {
    if (!this.audioWebReady || this.webUrl.length === 0) {
      return;
    }
    const html = `<!DOCTYPE html><html><body><video id="a" autoplay playsinline></video><script>
var a=document.getElementById('a');
a.setAttribute('data-state','try');
window.bcPlay=function(urls){
  var i=0;
  function arm(){a.src=urls[i];a.playbackRate=${this.speed};var p=a.play();if(p&&p.catch){p.catch(function(){});}}
  a.onerror=function(){i++;if(i<urls.length){arm();}else{a.setAttribute('data-state','bad');}};
  a.onplaying=function(){a.setAttribute('data-state','ok');};
  arm();
};
</script></body></html>`;
    this.webPage += 1;
    try {
      this.audioWeb.loadData(html, 'text/html', 'UTF-8', 'https://www.youtube.com/');
    } catch (e) {
      this.playError = `k:play_fail|. ${e}`;
    }
  }

  private injectWebSources(): void {
    if (this.webPage === 0 || this.webInjected === this.webPage || this.webList.length === 0) {
      return;
    }
    this.webInjected = this.webPage;
    const quoted: string[] = [];
    for (let i = 0; i < this.webList.length; i++) {
      quoted.push(`'${this.jsQuote(this.webList[i])}'`);
    }
    this.audioWeb.runJavaScript(`if(window.bcPlay){window.bcPlay([${quoted.join(',')}]);}`);
  }

  private pollWeb(): void {
    if (!this.audioWebReady || this.webUrl.length === 0 || this.webPollBusy || this.scrubbing) {
      return;
    }
    this.webPollBusy = true;
    const token = this.webToken;
    this.audioWeb.runJavaScript(
      '(function(){var a=document.getElementById("a");if(!a)return "none";var bad=a.getAttribute("data-state")==="bad";var err=bad?(a.error?a.error.code:4):0;var dur=isFinite(a.duration)?a.duration:0;return a.currentTime+","+dur+","+(a.paused?0:1)+","+err+","+(a.ended?1:0);})()'
    ).then((raw: string) => {
      this.webPollBusy = false;
      if (token === this.webToken) {
        this.applyWebReport(raw);
      }
    }).catch(() => {
      this.webPollBusy = false;
    });
  }

  private applyWebReport(raw: string): void {
    const text = raw.replace(/"/g, '');
    if (text.length === 0 || text === 'none') {
      return;
    }
    const parts = text.split(',');
    if (parts.length < 5) {
      return;
    }
    const err = Number(parts[3]);
    if (err > 0) {
      this.playing = false;
      this.playError = 'k:play_denied';
      this.webUrl = '';
      this.syncSession(true);
      return;
    }
    const position = Number(parts[0]) * 1000;
    const duration = Number(parts[1]) * 1000;
    const paused = parts[2] !== '1';
    const ended = parts[4] === '1';
    if (position >= 0) {
      this.positionMs = position;
    }
    if (duration > 0) {
      this.durationMs = duration;
    }
    this.playing = !paused && !ended;
    if (this.playing) {
      this.playError = '';
    }
    this.syncLyric(this.positionMs);
    this.syncSession(false);
    if (ended && position > 1000) {
      this.webUrl = '';
      this.advance(true, 1);
    }
  }

  private failSource(token: number, av: media.AVPlayer, code: number): void {
    if (token !== this.playToken || this.player !== av) {
      return;
    }
    this.player = null;
    av.release();
    const next = this.audioSourceIndex + 1;
    if (next < this.audioSources.length) {
      this.audioSourceIndex = next;
      const source = this.audioSources[next];
      this.attachPlayer(source.url, source.userAgent, token);
      return;
    }
    this.notePlaybackError(token, code);
  }

  private watchPlayer(av: media.AVPlayer, token: number): void {
    av.on('amplitudeUpdate', (amps: Array<number>) => {
      if (this.nextPlayer === av && this.player !== av) {
        return;
      }
      if (this.player !== av) {
        return;
      }
      let peak = 0;
      for (let i = 0; i < amps.length; i++) {
        const sample = amps[i] < 0 ? -amps[i] : amps[i];
        if (sample > peak) {
          peak = sample;
        }
      }
      if (peak > 100) {
        peak = peak / 32767;
      } else if (peak > 1) {
        peak = peak / 100;
      }
      this.onAmplitude(peak);
    });
    av.on('stateChange', (state: string) => {
      if (this.nextPlayer === av && this.player !== av) {
        if (state === 'initialized') {
          const info: audio.AudioRendererInfo = {
            usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
            rendererFlags: 0,
          };
          try {
            av.audioRendererInfo = info;
          } catch (_e) {
          }
          av.prepare();
        } else if (state === 'prepared') {
          try {
            av.setVolume(0);
            av.setSpeed(this.speedEnum());
          } catch (_e) {
          }
          this.nextReady = true;
          this.nextLoading = false;
        } else if (state === 'error') {
          this.failNext();
        }
        return;
      }
      if (this.player !== av) {
        return;
      }
      if (state === 'initialized') {
        const info: audio.AudioRendererInfo = {
          usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
          rendererFlags: 0,
        };
        try {
          av.audioRendererInfo = info;
        } catch (_e) {
        }
        this.bindSurface(av);
        av.prepare();
      } else if (state === 'prepared') {
        this.durationMs = av.duration > 0 ? av.duration : this.durationMs;
        av.setSpeed(this.speedEnum());
        this.fadeGain = 1;
        this.pushVolume(av);
        this.applyEffect();
        this.pushLoudness(this.loudnessOn ? this.loudnessDb : 0);
        this.readStats(av);
        if (this.wantSound && !this.wantsGraph()) {
          av.play();
        } else if (this.wantsGraph()) {
          this.applyEq();
        }
      } else if (state === 'playing') {
        this.playError = '';
        this.playing = true;
        this.refreshOutput();
        this.applyEffect();
        this.syncSession(true);
      } else if (state === 'paused') {
        this.playing = false;
        this.syncSession(true);
      } else if (state === 'completed') {
        if (this.fadeAdvanced) {
          return;
        }
        this.playing = false;
        this.fadeAdvanced = true;
        this.advance(true, 1);
      } else if (state === 'error') {
        this.failSource(token, av, 0);
      }
    });
    av.on('timeUpdate', (time: number) => {
      if (this.nextPlayer === av && this.player !== av) {
        return;
      }
      if (this.player !== av || this.scrubbing || time < 0) {
        return;
      }
      this.positionMs = time;
      if (av.duration > 0) {
        this.durationMs = av.duration;
        this.maybeRetryLyrics();
      }
      if (this.wantSound) {
        this.playing = true;
        this.playError = '';
      }
      this.syncLyric(time);
      this.applyFade(time);
    });
    av.on('error', (err: BusinessError) => {
      if (this.nextPlayer === av && this.player !== av) {
        this.failNext();
        return;
      }
      if (this.player !== av) {
        return;
      }
      const code = err.code;
      const message = err.message;
      hilog.error(0x0000, 'BitChord', 'player %{public}d %{public}s', code, message);
      this.failSource(token, av, code);
    });
  }

  private async attachPlayer(url: string, userAgent: string, token: number, savedFd: number = -1): Promise<void> {
    await this.releasePlayer();
    if (token !== this.playToken) {
      return;
    }
    const av = await media.createAVPlayer();
    this.player = av;
    this.watchPlayer(av, token);
    let file: media.AVFileDescriptor | null = null;
    if (savedFd >= 0) {
      this.audioFd = savedFd;
      let length = 0;
      try {
        length = fileIo.statSync(this.playingPath).size;
      } catch (_e) {
      }
      file = { fd: savedFd, offset: 0, length: length };
    } else {
      file = await this.cacheAudio(url, userAgent);
    }
    if (token !== this.playToken || this.player !== av || file === null) {
      if (file === null && token === this.playToken) {
        this.failSource(token, av, 0);
      }
      return;
    }
    av.fdSrc = file;
  }

  private async cacheAudio(url: string, userAgent: string, side: boolean = false): Promise<media.AVFileDescriptor | null> {
    const dir = this.cacheDir();
    if (dir.length === 0) {
      this.lastFault = 'không có thư mục tạm';
      return null;
    }
    if (side) {
      if (this.nextFd >= 0) {
        try {
          fileIo.closeSync(this.nextFd);
        } catch (_e) {
        }
        this.nextFd = -1;
      }
    } else {
      this.closeAudioFile();
    }
    const path = side ? `${dir}/bitchord-next.mp4` : `${dir}/bitchord-now.mp4`;
    const session = rcp.createSession();
    try {
      const opened = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      this.audioFd = opened.fd;
      let start = 0;
      let total = -1;
      const chunk = 1024 * 1024;
      const headers: rcp.RequestHeaders = { 'user-agent': userAgent };
      while (total < 0 || start < total) {
        const range: rcp.TransferRange = { from: start, to: start + chunk - 1 };
        const request = new rcp.Request(url, 'GET', headers);
        request.transferRange = range;
        const response = await session.fetch(request);
        if (response.statusCode === 416 && start > 0) {
          break;
        }
        if (response.statusCode < 200 || response.statusCode >= 300 || response.body === undefined) {
          this.lastFault = `HTTP ${response.statusCode}`;
          return null;
        }
        const bytes = response.body;
        if (bytes.byteLength < 1) {
          break;
        }
        fileIo.writeSync(opened.fd, bytes);
        const span = this.rangeTotal(response.headers);
        if (span > 0) {
          total = span;
        }
        start += bytes.byteLength;
        if (response.statusCode === 200 || bytes.byteLength < chunk) {
          break;
        }
        if (start > 160 * 1024 * 1024) {
          break;
        }
      }
      if (start < 1024) {
        this.lastFault = `tệp ${start} byte`;
        return null;
      }
      const stat = fileIo.statSync(path);
      if (side) {
        this.nextFd = opened.fd;
        this.nextPath = path;
      } else {
        this.keepDownload(path);
        this.audioFd = opened.fd;
        this.playingPath = path;
      }
      const desc: media.AVFileDescriptor = {
        fd: opened.fd,
        offset: 0,
        length: stat.size
      };
      return desc;
    } catch (e) {
      this.lastFault = `${e}`;
      hilog.error(0x0000, 'BitChord', 'cache %{public}s', this.lastFault);
      return null;
    } finally {
      session.close();
    }
  }

  private rangeTotal(headers: rcp.ResponseHeaders): number {
    const raw = headers['content-range'];
    const text = typeof raw === 'string' ? raw : '';
    const slash = text.lastIndexOf('/');
    if (slash < 0) {
      return -1;
    }
    const total = parseInt(text.slice(slash + 1), 10);
    return total > 0 ? total : -1;
  }

  private contentRangeTotal(headers: Object): number {
    const rec = headers as Record<string, Object>;
    const keys = Object.keys(rec);
    let raw = '';
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() === 'content-range') {
        raw = `${rec[keys[i]]}`;
        break;
      }
    }
    const slash = raw.lastIndexOf('/');
    if (slash < 0) {
      return -1;
    }
    const total = parseInt(raw.slice(slash + 1), 10);
    return total > 0 ? total : -1;
  }

  private cacheDir(): string {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return '';
    }
    return (host as common.UIAbilityContext).cacheDir;
  }

  private closeAudioFile(): void {
    if (this.audioFd < 0) {
      return;
    }
    try {
      fileIo.closeSync(this.audioFd);
    } catch (_e) {
    }
    this.audioFd = -1;
  }

  private async releasePlayer(): Promise<void> {
    this.failNext();
    const current = this.player;
    this.player = null;
    if (current !== null) {
      try {
        await current.release();
      } catch (_e) {
      }
    }
    this.closeAudioFile();
  }

  private async startLyrics(song: Song, token: number): Promise<void> {
    try {
      const duration = this.durationMs > 0 ? this.durationMs : song.durationMillis();
      this.lyricFetchedDuration = duration;
      const found = await lookupLyrics(new LyricsTrack(
        song.videoId,
        song.title,
        creditArtist(song.artist),
        duration,
        song.albumName
      ));
      if (token !== this.playToken) {
        return;
      }
      if (found === null || found.lines.length === 0) {
        this.lyricStatus = 'k:lyric_none';
        this.lyricLines = [];
        return;
      }
      this.lyricLines = found.lines;
      this.lyricStatus = found.label;
      this.syncLyric(this.positionMs);
      this.syncSession(true);
    } catch (_e) {
      if (token === this.playToken) {
        this.lyricStatus = 'k:lyric_fail';
      }
    }
  }

  private maybeRetryLyrics(): void {
    if (this.lyricRetry || this.durationMs < 15000 || this.trackVideoId.length === 0) {
      return;
    }
    const used = this.lyricFetchedDuration;
    const close = used > 0 && Math.abs(this.durationMs - used) < 8000;
    if (this.lyricLines.length > 0 && close) {
      return;
    }
    if (this.lyricLines.length === 0 && close && this.lyricStatus !== 'k:lyric_search') {
      return;
    }
    this.lyricRetry = true;
    this.startLyrics(this.currentSong(), this.playToken);
  }

  private soundOn(): boolean {
    return this.playing && this.playError.length === 0;
  }

  private notePlaybackError(token: number, code: number): void {
    if (token !== this.playToken || this.playError.length > 0) {
      return;
    }
    if (!this.effectRetry && this.audioId.length > 0) {
      this.effectRetry = true;
      this.playing = false;
      this.playError = '';
      this.startAudio(this.audioId, token);
      return;
    }
    this.playing = false;
    const suffix = code > 0 ? ` (${code})` : '';
    const detail = this.lastFault.length > 0 ? ` ${this.lastFault}` : '';
    this.playError = `k:play_fail|${suffix}.${detail}`;
    this.syncSession(true);
  }

  private togglePlay(): void {
    if (this.eqHolding && this.playError.length === 0) {
      if (this.playing) {
        this.wantSound = false;
        this.playing = false;
        this.audioWeb.runJavaScript('var a=document.getElementById("a");if(a)a.pause();');
      } else {
        this.wantSound = true;
        this.playing = true;
        this.audioWeb.runJavaScript('var a=document.getElementById("a");if(a)a.play();');
      }
      this.syncSession(true);
      return;
    }
    if (this.webUrl.length > 0 && this.playError.length === 0) {
      if (this.playing) {
        this.wantSound = false;
        this.playing = false;
        this.audioWeb.runJavaScript('var a=document.getElementById("a");if(a)a.pause();');
      } else {
        this.wantSound = true;
        this.playing = true;
        this.audioWeb.runJavaScript('var a=document.getElementById("a");if(a)a.play();');
      }
      this.syncSession(true);
      return;
    }
    const av = this.player;
    if (av === null || this.playError.length > 0) {
      if (this.trackVideoId.length > 0) {
        this.playError = '';
        this.effectRetry = false;
        this.playToken += 1;
        this.startAudio(this.trackVideoId, this.playToken);
      }
      return;
    }
    if (this.playing) {
      this.wantSound = false;
      av.pause();
    } else {
      this.wantSound = true;
      av.play();
    }
  }

  private seekTo(ms: number): void {
    if (this.eqHolding) {
      this.positionMs = ms;
      this.audioWeb.runJavaScript(`var a=document.getElementById("a");if(a)a.currentTime=${ms / 1000};`);
      return;
    }
    if (this.webUrl.length > 0) {
      this.positionMs = ms;
      this.audioWeb.runJavaScript(`var a=document.getElementById("a");if(a)a.currentTime=${ms / 1000};`);
      return;
    }
    const av = this.player;
    if (av !== null) {
      av.seek(ms);
    }
  }

  private skip(delta: number): void {
    this.advance(false, delta);
  }

  private advance(fromComplete: boolean, delta: number): void {
    if (this.queue.length === 0) {
      return;
    }
    if (fromComplete && this.stopAfterTrack) {
      this.stopAfterTrack = false;
      this.sleepChoice = 0;
      this.playing = false;
      return;
    }
    if (fromComplete && this.repeatMode === 2) {
      this.playAt(this.queueIndex);
      return;
    }
    if (delta > 0 && this.nextReady && this.nextPlayer !== null) {
      const planned = this.upcomingIndex();
      if (planned >= 0) {
        this.commitNext(planned);
        return;
      }
    }
    if (this.shuffle && delta > 0 && this.queue.length > 1) {
      let next = this.queueIndex;
      while (next === this.queueIndex) {
        next = Math.floor(Math.random() * this.queue.length);
      }
      this.playAt(next);
      return;
    }
    let next = this.queueIndex + delta;
    if (next >= this.queue.length) {
      if (this.repeatMode === 1) {
        next = 0;
      } else {
        this.playing = false;
        return;
      }
    }
    if (next < 0) {
      next = this.repeatMode === 1 ? this.queue.length - 1 : 0;
    }
    this.playAt(next);
  }

  private tick(): void {
    if (this.webParked) {
      const parked = this.player;
      if (parked !== null && !this.scrubbing) {
        this.positionMs = parked.currentTime;
        if (parked.duration > 0) {
          this.durationMs = parked.duration;
        }
        this.syncLyric(this.positionMs);
        this.applyFade(this.positionMs);
      }
      return;
    }
    if (this.eqHolding) {
      this.pollEq();
    }
    this.pollWeb();
    if (this.sleepDeadline > 0 && Date.now() >= this.sleepDeadline) {
      this.sleepDeadline = 0;
      this.sleepChoice = 0;
      const sleeping = this.player;
      if (sleeping !== null && this.playing) {
        sleeping.pause();
      }
      if (this.webUrl.length > 0) {
        this.audioWeb.runJavaScript('var a=document.getElementById("a");if(a)a.pause();');
      }
      this.playing = false;
      this.syncSession(true);
      return;
    }
    const av = this.player;
    if (av === null || this.scrubbing || !this.playing || this.eqHolding) {
      return;
    }
    this.positionMs = av.currentTime;
    if (av.duration > 0) {
      this.durationMs = av.duration;
    }
    this.syncLyric(this.positionMs);
    this.applyFade(this.positionMs);
    this.syncSession(false);
  }

  private closePlayer(): void {
    this.playerDrag = 0;
    this.screen = this.screenUnderPlayer;
  }

  private channelPhoto(ch: AccountChannel): string {
    return ch.thumbnailUrl !== null ? ch.thumbnailUrl : '';
  }

  private channelLine(ch: AccountChannel): string {
    const raw = ch.subtitle.trim();
    if (raw.length === 0) {
      return this.t('channel_word');
    }
    if (raw === 'No channel' || raw === 'No Channel' || raw === 'Không có kênh') {
      return '';
    }
    return raw;
  }

  private channelFile(): string {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return '';
    }
    return `${(host as common.UIAbilityContext).filesDir}/account.channel`;
  }

  private channelKey(pageId: string | null, dataSyncId: string | null): string {
    const page = pageId !== null ? pageId : '';
    const sync = dataSyncId !== null ? dataSyncId : '';
    return `${page}|${sync}`;
  }

  private writeChannel(pageId: string | null, dataSyncId: string | null): void {
    const path = this.channelFile();
    if (path.length === 0) {
      return;
    }
    try {
      const opened = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(opened.fd, this.channelKey(pageId, dataSyncId));
      fileIo.closeSync(opened.fd);
    } catch (_e) {
    }
  }

  private readChannel(): string {
    const path = this.channelFile();
    if (path.length === 0) {
      return '';
    }
    try {
      return fileIo.readTextSync(path).trim();
    } catch (_e) {
      return '';
    }
  }

  private restoreChannel(): void {
    const saved = this.readChannel();
    const cut = saved.indexOf('|');
    if (cut < 0) {
      return;
    }
    const page = saved.slice(0, cut);
    const sync = saved.slice(cut + 1);
    Innertube.selectChannel(page.length > 0 ? page : null, sync.length > 0 ? sync : null, null);
  }

  private useChannel(index: number): void {
    if (index < 0 || index >= this.accountChannels.length) {
      return;
    }
    const picked = this.accountChannels[index];
    if (picked.activeOnWeb) {
      this.sheet = '';
      return;
    }
    const next: Array<AccountChannel> = [];
    for (let i = 0; i < this.accountChannels.length; i++) {
      const src = this.accountChannels[i];
      next.push(new AccountChannel(src.name, src.subtitle, src.thumbnailUrl, src.pageId, src.dataSyncId, i === index));
    }
    this.accountChannels = next;
    Innertube.selectChannel(picked.pageId, picked.dataSyncId, null);
    this.writeChannel(picked.pageId, picked.dataSyncId);
    const photo = this.channelPhoto(picked);
    if (photo.length > 0) {
      this.accountPhoto = photo;
    }
    if (picked.subtitle.indexOf('@') >= 0) {
      this.accountHandle = picked.subtitle;
    } else if (picked.name.length > 0) {
      this.accountHandle = picked.name;
    }
    this.sheet = '';
    this.librarySongs = [];
    this.libraryItems = [];
    this.loadHome();
    if (this.tab === 2) {
      this.loadLibrary();
    }
  }

  private openAccount(): void {
    this.sheet = 'account';
    if (this.signedIn) {
      this.loadAccounts();
    }
  }

  private async loadAccounts(): Promise<void> {
    if (!this.signedIn) {
      return;
    }
    try {
      const menu = await Innertube.accountMenu();
      const account = InnertubeParser.parseAccount(menu);
      let channels = InnertubeParser.parseAccountChannels(menu);
      if (channels.length === 0) {
        const listed = await Innertube.accountsList();
        channels = InnertubeParser.parseAccountChannels(listed);
      }
      if (channels.length === 0) {
        const switched = await Innertube.accountSwitcher();
        channels = InnertubeParser.parseAccountChannels(switched);
      }
      const saved = this.readChannel();
      let chosen = -1;
      for (let i = 0; i < channels.length; i++) {
        if (saved.length > 0 && this.channelKey(channels[i].pageId, channels[i].dataSyncId) === saved) {
          chosen = i;
          break;
        }
      }
      if (chosen < 0) {
        for (let i = 0; i < channels.length; i++) {
          if (channels[i].activeOnWeb) {
            chosen = i;
            break;
          }
        }
      }
      if (chosen < 0) {
        for (let i = 0; i < channels.length; i++) {
          if (channels[i].subtitle.indexOf('@') >= 0) {
            chosen = i;
            break;
          }
        }
      }
      if (chosen < 0) {
        chosen = 0;
      }
      const shown: Array<AccountChannel> = [];
      for (let i = 0; i < channels.length; i++) {
        const src = channels[i];
        shown.push(new AccountChannel(src.name, src.subtitle, src.thumbnailUrl, src.pageId, src.dataSyncId, i === chosen));
      }
      this.accountChannels = shown;
      const current = shown[chosen];
      Innertube.selectChannel(current.pageId, current.dataSyncId, null);
      this.writeChannel(current.pageId, current.dataSyncId);
      let handle = '';
      for (let i = 0; i < shown.length; i++) {
        if (shown[i].subtitle.indexOf('@') >= 0) {
          handle = shown[i].subtitle;
          break;
        }
      }
      if (handle.length === 0) {
        handle = current.name;
      }
      let photo = this.channelPhoto(current);
      if (photo.length === 0 && account !== null && account.thumbnailUrl !== null) {
        photo = account.thumbnailUrl;
      }
      this.accountHandle = handle;
      this.accountPhoto = photo;
    } catch (_e) {
    }
  }

  private openLogin(): void {
    try {
      webview.WebCookieManager.clearAllCookiesSync();
    } catch (_e) {
    }
    this.screen = 'login';
  }

  private finishLogin(cookie: string): void {
    this.accountCookie = cookie;
    this.signedIn = true;
    Innertube.cookie = cookie;
    this.writeSession(cookie);
    this.applyWebCookies(cookie);
    this.persistStore();
    this.screen = 'tabs';
    this.tab = 2;
    this.libraryKind = 'songs';
    this.loadLibrary();
    this.loadAccounts();
  }

  private signOut(): void {
    this.accountCookie = '';
    this.signedIn = false;
    this.accountHandle = '';
    this.accountPhoto = '';
    this.accountChannels = [];
    Innertube.selectChannel(null, null, null);
    try {
      const channelPath = this.channelFile();
      if (channelPath.length > 0) {
        fileIo.unlinkSync(channelPath);
      }
    } catch (_e) {
    }
    this.librarySongs = [];
    this.libraryItems = [];
    Innertube.cookie = null;
    this.writeSession('');
    try {
      webview.WebCookieManager.clearAllCookiesSync();
    } catch (_e) {
    }
    this.persistStore();
  }

  private loadLibrary(): void {
    if (this.libraryKind === 'replay') {
      this.libraryLoading = false;
      this.libraryError = '';
      this.libraryItems = [];
      this.librarySongs = this.recentSongs.slice();
      return;
    }
    if (!this.signedIn) {
      return;
    }
    this.libraryLoading = true;
    this.libraryError = '';
    this.fetchLibrary();
  }

  private libraryBrowseId(): string {
    if (this.libraryKind === 'playlists') {
      return 'FEmusic_liked_playlists';
    }
    if (this.libraryKind === 'albums') {
      return 'FEmusic_liked_albums';
    }
    if (this.libraryKind === 'history') {
      return 'FEmusic_history';
    }
    return 'VLLM';
  }

  private async fetchLibrary(): Promise<void> {
    const kind = this.libraryKind;
    try {
      const response = await Innertube.browse(this.libraryBrowseId());
      if (kind !== this.libraryKind) {
        return;
      }
      const shelf = InnertubeParser.parsePlaylistShelf(response);
      if (shelf !== null && shelf.songs.length > 0) {
        this.librarySongs = shelf.songs;
        this.libraryItems = [];
      } else {
        this.librarySongs = [];
        this.libraryItems = InnertubeParser.parseLibraryItems(response);
      }
      if (this.librarySongs.length === 0 && this.libraryItems.length === 0) {
        this.libraryError = 'k:library_bad';
      }
    } catch (_e) {
      if (kind === this.libraryKind) {
        this.libraryError = 'k:library_fail';
      }
    }
    this.libraryLoading = false;
  }

  private playPartyCode(): void {
    const code = this.partyCode.trim();
    if (code.length < 11) {
      this.notice = 'k:party_bad';
      return;
    }
    this.sheet = '';
    this.screen = 'tabs';
    this.playSongs([new Song(code, code, '', null)], 0);
  }

  private applyEffect(): void {
    const av = this.player;
    if (av === null) {
      return;
    }
    const widen = this.effectOn || this.spatialOn;
    try {
      av.audioEffectMode = widen ? audio.AudioEffectMode.EFFECT_DEFAULT : audio.AudioEffectMode.EFFECT_NONE;
    } catch (_e) {
    }
  }

  private noteSpatial(): void {
    if (!this.spatialOn) {
      this.notice = '';
      return;
    }
    try {
      const enabled = audio.getAudioManager().getSpatializationManager().isSpatializationEnabledForCurrentDevice();
      this.notice = enabled ? 'k:spatial_ready' : 'k:spatial_device_off';
    } catch (_e) {
      this.notice = 'k:spatial_device_off';
    }
  }

  private deviceTitle(): string {
    try {
      const host = this.getUIContext().getHostContext();
      if (host !== undefined) {
        const named = settings.getValueSync(host, settings.general.DEVICE_NAME, '');
        if (named.length > 0) {
          return named;
        }
      }
    } catch (_e) {
    }
    if (deviceInfo.marketName.length > 0) {
      return deviceInfo.marketName;
    }
    return 'Phone';
  }

  private formatRate(rate: number): string {
    if (rate >= 1000) {
      const khz = rate / 1000;
      const text = Math.abs(khz - Math.round(khz)) < 0.05 ? `${Math.round(khz)}` : khz.toFixed(1);
      return `${text} kHz`;
    }
    return `${rate} Hz`;
  }

  private refreshOutput(): void {
    const found: Array<audio.AudioDeviceDescriptor> = [];
    let activeId = -1;
    let rate = 44100;
    let channels = 2;
    try {
      const manager = audio.getAudioManager();
      const available = manager.getRoutingManager().getAvailableDevices(audio.DeviceUsage.MEDIA_OUTPUT_DEVICES);
      for (let i = 0; i < available.length; i++) {
        found.push(available[i]);
      }
      const playing = manager.getStreamManager().getCurrentAudioRendererInfoArraySync();
      for (let i = 0; i < playing.length; i++) {
        const devices = playing[i].deviceDescriptors;
        if (devices.length === 0) {
          continue;
        }
        activeId = devices[0].id;
        if (devices[0].sampleRates.length > 0) {
          rate = devices[0].sampleRates[0];
        }
        if (devices[0].channelCounts.length > 0) {
          channels = devices[0].channelCounts[0];
        }
        break;
      }
    } catch (_e) {
    }
    if (found.length === 0) {
      activeId = 0;
    }
    let chosen = 0;
    for (let i = 0; i < found.length; i++) {
      if (found[i].id === activeId) {
        chosen = i;
        break;
      }
    }
    const routes: Array<OutputRoute> = [];
    for (let i = 0; i < found.length; i++) {
      const device = found[i];
      const route = new OutputRoute();
      route.id = device.id;
      const titled = device.displayName.length > 0 ? device.displayName : device.name;
      route.name = titled.length > 0 ? titled : this.deviceTitle();
      route.selected = i === chosen;
      routes.push(route);
    }
    if (routes.length === 0) {
      const route = new OutputRoute();
      route.id = 0;
      route.name = this.deviceTitle();
      route.selected = true;
      routes.push(route);
    }
    this.outputDescs = found;
    this.outputRoutes = routes;
    const current = routes[chosen] !== undefined ? routes[chosen] : routes[0];
    this.outputName = current.name;
    const live = `${this.formatRate(rate)} · ${channels} ch`;
    this.outputDetail = live;
    this.pipeChoices = this.pipeList(found.length > 0 ? found[chosen] : null, rate, channels, live);
  }

  private pipeList(device: audio.AudioDeviceDescriptor | null, rate: number, channels: number, live: string): Array<PipeChoice> {
    const labels: Array<string> = [];
    labels.push(live);
    if (device !== null) {
      const rates = device.sampleRates;
      const counts = device.channelCounts.length > 0 ? device.channelCounts : [channels];
      for (let r = 0; r < rates.length; r++) {
        for (let c = 0; c < counts.length; c++) {
          const label = `${this.formatRate(rates[r])} · ${counts[c]} ch`;
          if (!labels.includes(label)) {
            labels.push(label);
          }
        }
      }
    }
    const rows: Array<PipeChoice> = [];
    for (let i = 0; i < labels.length; i++) {
      const row = new PipeChoice();
      row.label = labels[i];
      row.selected = labels[i] === live;
      rows.push(row);
    }
    return rows;
  }

  private async pickOutput(index: number): Promise<void> {
    if (index < 0 || index >= this.outputRoutes.length) {
      return;
    }
    const next: Array<OutputRoute> = [];
    for (let i = 0; i < this.outputRoutes.length; i++) {
      const src = this.outputRoutes[i];
      const route = new OutputRoute();
      route.id = src.id;
      route.name = src.name;
      route.selected = i === index;
      next.push(route);
    }
    this.outputRoutes = next;
    this.outputName = next[index].name;
    if (index < this.outputDescs.length) {
      try {
        const enhance = audio.getAudioManager().getDeviceEnhanceManager();
        if (enhance.isEnhancedRoutingSupported()) {
          await enhance.selectOutputDevice(this.outputDescs[index]);
        }
      } catch (_e) {
      }
    }
  }

  private pickPipe(index: number): void {
    if (index < 0 || index >= this.pipeChoices.length) {
      return;
    }
    const next: Array<PipeChoice> = [];
    for (let i = 0; i < this.pipeChoices.length; i++) {
      const row = new PipeChoice();
      row.label = this.pipeChoices[i].label;
      row.selected = i === index;
      next.push(row);
    }
    this.pipeChoices = next;
    this.outputDetail = next[index].label;
    this.outputPane = 'devices';
  }

  private readOutput(): string {
    try {
      const devices = audio.getAudioManager().getRoutingManager()
        .getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
      for (let i = 0; i < devices.length; i++) {
        const kind = devices[i].deviceType;
        if (kind === audio.DeviceType.USB_HEADSET || kind === audio.DeviceType.USB_DEVICE) {
          return 'USB';
        }
        if (kind === audio.DeviceType.BLUETOOTH_A2DP || kind === audio.DeviceType.BLUETOOTH_SCO) {
          return 'Bluetooth';
        }
        if (kind === audio.DeviceType.WIRED_HEADSET || kind === audio.DeviceType.WIRED_HEADPHONES) {
          return 'Tai nghe dây';
        }
        if (kind === audio.DeviceType.SPEAKER) {
          return 'Loa máy';
        }
      }
    } catch (_e) {
    }
    return 'Loa máy';
  }

  private async restoreStore(): Promise<void> {
    let host: common.UIAbilityContext | null = null;
    try {
      const raw = this.getUIContext().getHostContext();
      if (raw === undefined) {
        return;
      }
      host = raw as common.UIAbilityContext;
    } catch (_e) {
      return;
    }
    if (host === null) {
      return;
    }
    const stored = await PlayStore.load(host);
    this.repeatMode = stored.repeatMode;
    this.shuffle = stored.shuffle;
    this.speed = stored.speed > 0 ? stored.speed : 1;
    this.wifiQuality = stored.wifi === 'saver' ? 'saver' : 'auto';
    this.cellQuality = stored.cell === 'saver' ? 'saver' : 'auto';
    this.effectOn = stored.effectOn;
    this.fullArt = stored.fullArt;
    this.syncedOn = stored.syncedOn;
    this.statsOn = stored.statsOn;
    this.jioOn = stored.jioOn;
    this.extensionUrls = stored.extensions;
    this.webdavUrl = stored.webdavUrl;
    this.webdavUser = stored.webdavUser;
    this.webdavPass = stored.webdavPass;
    this.shareUri = stored.shareUri;
    this.applyFlags(stored.flags);
    this.pushRegion();
    this.webdavState = stored.webdavUrl.length > 0 ? 'k:webdav_saved' : '';
    if (this.accountCookie.length === 0) {
      const savedCookie = this.readSession();
      this.accountCookie = savedCookie.length > 0 ? savedCookie : stored.cookie;
      this.signedIn = this.accountCookie.indexOf('SAPISID=') >= 0 || this.accountCookie.indexOf('__Secure-3PAPISID=') >= 0;
      if (this.signedIn) {
        Innertube.cookie = this.accountCookie;
        if (savedCookie.length === 0) {
          this.writeSession(this.accountCookie);
        }
        this.applyWebCookies(this.accountCookie);
      }
    }
    this.sessionReady = true;
    this.recentSongs = this.unpackSongs(stored.recent);
    if (this.signedIn) {
      this.restoreChannel();
      this.loadAccounts();
    }
    this.refreshOutput();
  }

  private persistStore(): void {
    this.persistStoreNow();
  }

  private persistStoreNow(): Promise<void> {
    if (!this.sessionReady && this.accountCookie.length === 0) {
      return Promise.resolve();
    }
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return Promise.resolve();
    }
    const data = new StoredPlay();
    data.repeatMode = this.repeatMode;
    data.shuffle = this.shuffle;
    data.speed = this.speed;
    data.wifi = this.wifiQuality;
    data.cell = this.cellQuality;
    data.recent = this.packSongs(this.recentSongs);
    data.cookie = '';
    data.effectOn = this.effectOn;
    data.fullArt = this.fullArt;
    data.syncedOn = this.syncedOn;
    data.statsOn = this.statsOn;
    data.jioOn = this.jioOn;
    data.extensions = this.extensionUrls;
    data.webdavUrl = this.webdavUrl;
    data.webdavUser = this.webdavUser;
    data.webdavPass = this.webdavPass;
    data.shareUri = this.shareUri;
    data.flags = this.writeFlags();
    return PlayStore.save(host as common.UIAbilityContext, data);
  }

  private packSongs(songs: Array<Song>): string {
    const lines: Array<string> = [];
    for (let i = 0; i < songs.length && i < 30; i++) {
      const song = songs[i];
      const art = song.thumbnailUrl !== null ? song.thumbnailUrl : '';
      lines.push(`${song.videoId}\u001f${song.title}\u001f${song.artist}\u001f${art}`);
    }
    return lines.join('\n');
  }

  private unpackSongs(raw: string): Array<Song> {
    const songs: Array<Song> = [];
    if (raw.length === 0) {
      return songs;
    }
    const lines = raw.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const parts = lines[i].split('\u001f');
      if (parts.length >= 3 && parts[0].length > 0) {
        const art = parts.length > 3 && parts[3].length > 0 ? parts[3] : null;
        songs.push(new Song(parts[0], parts[1], parts[2], art));
      }
    }
    return songs;
  }

  private playbackCap(): number {
    return this.bitrateCap();
  }

  private page(): string {
    return this.uiDark ? BG : '#F2F2F7';
  }

  private card(): string {
    return this.uiDark ? CARD : '#FFFFFF';
  }

  private ink(): string {
    return this.uiDark ? TEXT : '#16161A';
  }

  private muted(): string {
    return this.uiDark ? MUTED : '#6E6E73';
  }

  private applyTheme(): void {
    let dark = true;
    if (this.themeMode === 'light') {
      dark = false;
    } else if (this.themeMode === 'system') {
      try {
        const host = this.getUIContext().getHostContext() as common.UIAbilityContext;
        dark = host.config.colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      } catch (_e) {
      }
    }
    this.uiDark = dark;
    try {
      const host = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const mode = this.themeMode === 'light'
        ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : this.themeMode === 'dark'
          ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
          : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      host.getApplicationContext().setColorMode(mode);
    } catch (_e) {
    }
  }

  private mixLabel(): string {
    if (this.mixPerf === 'fast') {
      return this.t('mix_fast');
    }
    if (this.mixPerf === 'quality') {
      return this.t('mix_quality');
    }
    return this.t('mix_balanced');
  }

  private cycleMix(): void {
    if (this.mixPerf === 'fast') {
      this.mixPerf = 'balanced';
    } else if (this.mixPerf === 'balanced') {
      this.mixPerf = 'quality';
    } else {
      this.mixPerf = 'fast';
    }
    this.persistStore();
  }

  private fadeMs(): number {
    let windowMs = this.crossfade > 0 ? this.crossfade * 1000 : 0;
    if (this.automix) {
      let mix = 8000;
      if (this.mixPerf === 'fast') {
        mix = 4000;
      } else if (this.mixPerf === 'quality') {
        mix = 12000;
      }
      if (mix > windowMs) {
        windowMs = mix;
      }
    }
    return windowMs;
  }

  private outputVolume(fade: number): number {
    let lin = 1;
    if (this.loudnessOn && !this.loudnessGainLive && this.loudnessDb < 0) {
      lin = Math.pow(10, this.loudnessDb / 20);
    }
    const value = this.playVolume * fade * lin;
    if (value < 0) {
      return 0;
    }
    if (value > 1) {
      return 1;
    }
    return value;
  }

  private pushVolume(av: media.AVPlayer | null): void {
    if (av === null) {
      return;
    }
    try {
      av.setVolume(this.outputVolume(this.player === av ? this.fadeGain : 1));
    } catch (_e) {
    }
  }

  private upcomingIndex(): number {
    if (this.queue.length === 0 || this.repeatMode === 2) {
      return -1;
    }
    if (this.plannedNext >= 0 && this.plannedNext < this.queue.length && this.plannedNext !== this.queueIndex) {
      return this.plannedNext;
    }
    if (this.shuffle && this.queue.length > 1) {
      let next = this.queueIndex;
      while (next === this.queueIndex) {
        next = Math.floor(Math.random() * this.queue.length);
      }
      this.plannedNext = next;
      return next;
    }
    const next = this.queueIndex + 1;
    if (next >= this.queue.length) {
      return this.repeatMode === 1 ? 0 : -1;
    }
    return next;
  }

  private queuePrefetch(): void {
    if (this.fadeMs() <= 0 || this.nextLoading || this.nextReady || this.nextPlayer !== null) {
      return;
    }
    const index = this.upcomingIndex();
    if (index < 0) {
      return;
    }
    this.nextLoading = true;
    const token = this.playToken;
    this.loadNext(this.queue[index], token);
  }

  private openRead(path: string): number {
    if (path.length === 0) {
      return -1;
    }
    try {
      if (fileIo.statSync(path).size < 1024) {
        return -1;
      }
      return fileIo.openSync(path, fileIo.OpenMode.READ_ONLY).fd;
    } catch (_e) {
      return -1;
    }
  }

  private failNext(): void {
    const av = this.nextPlayer;
    this.nextPlayer = null;
    this.nextReady = false;
    this.nextStarted = false;
    this.nextLoading = false;
    if (av !== null) {
      try {
        av.release();
      } catch (_e) {
      }
    }
    if (this.nextFd >= 0) {
      try {
        fileIo.closeSync(this.nextFd);
      } catch (_e) {
      }
      this.nextFd = -1;
    }
    this.nextPath = '';
  }

  private async loadNext(song: Song, token: number): Promise<void> {
    const saved = this.openRead(this.downloadFile(song.videoId));
    if (saved >= 0) {
      this.nextFd = saved;
      this.nextPath = this.downloadFile(song.videoId);
    } else {
      const muxed = await Innertube.resolveMuxedUrl(song.videoId, this.playbackCap());
      if (token !== this.playToken) {
        this.nextLoading = false;
        return;
      }
      if (muxed.sources.length === 0) {
        this.nextLoading = false;
        return;
      }
      const first = muxed.sources[0];
      const desc = await this.cacheAudio(first.url, first.userAgent, true);
      if (token !== this.playToken || desc === null) {
        this.failNext();
        return;
      }
    }
    if (token !== this.playToken) {
      this.failNext();
      return;
    }
    await this.armStandby(token);
  }

  private async armStandby(token: number): Promise<void> {
    const av = await media.createAVPlayer();
    if (token !== this.playToken || this.nextFd < 0) {
      try {
        av.release();
      } catch (_e) {
      }
      this.failNext();
      return;
    }
    this.nextPlayer = av;
    this.watchPlayer(av, token);
    let length = 0;
    try {
      length = fileIo.statSync(this.nextPath).size;
    } catch (_e) {
    }
    av.fdSrc = { fd: this.nextFd, offset: 0, length: length };
  }

  private commitNext(index: number): void {
    const incoming = this.nextPlayer;
    if (incoming === null || index < 0 || index >= this.queue.length) {
      this.playAt(index);
      return;
    }
    if (this.eqHolding || this.eqPage > 0) {
      this.stopEqWeb(false);
    }
    const old = this.player;
    this.player = incoming;
    this.nextPlayer = null;
    this.nextReady = false;
    this.nextStarted = false;
    this.nextLoading = false;
    if (this.audioFd >= 0 && this.audioFd !== this.nextFd) {
      try {
        fileIo.closeSync(this.audioFd);
      } catch (_e) {
      }
    }
    this.audioFd = this.nextFd;
    this.nextFd = -1;
    this.playingPath = this.nextPath;
    this.nextPath = '';
    if (old !== null && old !== incoming) {
      try {
        old.pause();
      } catch (_e) {
      }
      old.release();
    }
    try {
      const at = incoming.currentTime;
      this.positionMs = at > 0 ? at : 0;
    } catch (_e) {
      this.positionMs = 0;
    }
    const song = this.showSong(index, false);
    try {
      this.durationMs = incoming.duration > 0 ? incoming.duration : song.durationMillis();
    } catch (_e) {
      this.durationMs = song.durationMillis();
    }
    this.fadeGain = 1;
    try {
      incoming.setVolume(this.outputVolume(1));
      this.bindSurface(incoming);
    } catch (_e) {
    }
    this.applyEffect();
    this.pushLoudness(this.loudnessOn ? this.loudnessDb : 0);
    this.startLyrics(song, this.playToken);
    this.syncSession(true);
    if (this.wantsGraph()) {
      try {
        incoming.pause();
      } catch (_e) {
      }
      this.armEq();
    } else if (this.wantSound) {
      try {
        incoming.play();
      } catch (_e) {
      }
    }
  }

  private applyFade(time: number): void {
    const windowMs = this.fadeMs();
    const av = this.player;
    if (av === null) {
      return;
    }
    if (windowMs <= 0 || this.durationMs <= windowMs + 400) {
      if (this.fadeGain !== 1) {
        this.fadeGain = 1;
        this.pushVolume(av);
      }
      return;
    }
    const end = this.mixCut > 0 ? this.mixCut : this.durationMs;
    const left = end - time;
    if (left < windowMs + 14000) {
      this.queuePrefetch();
    }
    if (left > windowMs) {
      if (this.fadeGain !== 1 && this.mixCut < 0) {
        this.fadeGain = 1;
        this.pushVolume(av);
      }
      return;
    }
    if (left < 0) {
      return;
    }
    this.fadeGain = left / windowMs;
    if (this.eqHolding && this.audioWebReady) {
      this.audioWeb.runJavaScript(`var a=document.getElementById('a');if(a){a.volume=${this.fadeGain};}`);
    } else {
      this.pushVolume(av);
    }
    if (this.nextReady && this.nextPlayer !== null) {
      if (!this.nextStarted) {
        this.nextStarted = true;
        try {
          this.nextPlayer.play();
        } catch (_e) {
        }
      }
      try {
        this.nextPlayer.setVolume(this.outputVolume(1 - this.fadeGain));
      } catch (_e) {
      }
      if (this.fadeGain < 0.05 && !this.fadeAdvanced) {
        this.fadeAdvanced = true;
        const index = this.upcomingIndex();
        if (index >= 0) {
          this.commitNext(index);
        }
      }
      return;
    }
    if (left < 350 && !this.fadeAdvanced) {
      this.fadeAdvanced = true;
      this.advance(true, 1);
    }
  }

  private onAmplitude(peak: number): void {
    if (this.skipSilence && this.playing && peak < 0.08 && this.player !== null) {
      if (this.silenceMs < 0) {
        this.silenceMs = this.positionMs;
      }
      if (this.positionMs - this.silenceMs > 700 && this.silenceSkips < 24 && this.durationMs > 0) {
        this.silenceSkips++;
        const jump = Math.min(this.positionMs + 1600, this.durationMs - 500);
        this.silenceMs = jump;
        this.seekTo(jump);
      }
    } else {
      this.silenceMs = -1;
    }
    if (this.automix && this.mixCut < 0 && this.durationMs > 0 && this.positionMs > 8000) {
      const remain = this.durationMs - this.positionMs;
      if (remain < this.fadeMs() + 2500 && remain > this.fadeMs() && peak < 0.045) {
        if (this.mixQuiet < 0) {
          this.mixQuiet = this.positionMs;
        }
        if (this.positionMs - this.mixQuiet > 600) {
          this.mixCut = this.positionMs + this.fadeMs();
          this.queuePrefetch();
        }
      } else {
        this.mixQuiet = -1;
      }
    }
    if (!this.loudnessOn) {
      if (this.loudnessDb !== 0) {
        this.loudnessDb = 0;
        this.pushLoudness(0);
        this.pushVolume(this.player);
      }
      return;
    }
    if (peak < 0.02) {
      return;
    }
    if (peak > this.loudnessPeak) {
      this.loudnessPeak = peak;
    } else {
      this.loudnessPeak = this.loudnessPeak * 0.992 + peak * 0.008;
    }
    const now = Date.now();
    if (now - this.loudnessStamp < 900) {
      return;
    }
    this.loudnessStamp = now;
    const basis = this.loudnessPeak < 0.02 ? 0.02 : this.loudnessPeak;
    let db = 20 * Math.log(0.18 / basis) / Math.log(10);
    if (db > 4) {
      db = 4;
    }
    if (db < -8) {
      db = -8;
    }
    if (Math.abs(db - this.loudnessDb) < 1.5) {
      return;
    }
    this.loudnessDb = db;
    this.pushLoudness(db);
  }

  private pushLoudness(db: number): void {
    this.pushLoudnessNow(db);
  }

  private async pushLoudnessNow(db: number): Promise<void> {
    const av = this.player;
    if (av === null) {
      return;
    }
    try {
      await av.setLoudnessGain(db);
      this.loudnessGainLive = true;
    } catch (_e) {
      this.loudnessGainLive = false;
    }
    this.pushVolume(av);
  }

  private async readStats(av: media.AVPlayer): Promise<void> {
    if (!this.statsOn) {
      this.trackStat = '';
      return;
    }
    try {
      const tracks = await av.getTrackDescription();
      let codec = '';
      let rate = 0;
      let channels = 0;
      let bitrate = 0;
      for (let i = 0; i < tracks.length; i++) {
        const row = tracks[i];
        const mime = row[media.MediaDescriptionKey.MD_KEY_CODEC_MIME];
        if (typeof mime === 'string' && mime.indexOf('audio/') === 0) {
          codec = mime;
          const sample = row[media.MediaDescriptionKey.MD_KEY_AUD_SAMPLE_RATE];
          const count = row[media.MediaDescriptionKey.MD_KEY_AUD_CHANNEL_COUNT];
          const bits = row[media.MediaDescriptionKey.MD_KEY_BITRATE];
          if (typeof sample === 'number') {
            rate = sample;
          }
          if (typeof count === 'number') {
            channels = count;
          }
          if (typeof bits === 'number') {
            bitrate = bits;
          }
        }
      }
      const parts: Array<string> = [];
      if (codec.length > 0) {
        parts.push(codec.replace('audio/', ''));
      }
      if (bitrate > 0) {
        parts.push(`${Math.round(bitrate / 1000)} kbps`);
      }
      if (rate > 0) {
        parts.push(`${Math.round(rate / 1000)} kHz`);
      }
      if (channels > 0) {
        parts.push(`${channels} ch`);
      }
      this.trackStat = parts.join(' · ');
    } catch (_e) {
      this.trackStat = '';
    }
  }

  private dotIndex(): Array<number> {
    return [0, 1, 2, 3, 4, 5, 6, 7];
  }

  private knobX(): number {
    return ((this.toneX + 10) / 20) * (320 - 34);
  }

  private knobY(): number {
    return ((10 - this.toneY) / 20) * (230 - 34);
  }

  private setTone(x: number, y: number, save: boolean): void {
    this.toneX = Math.round(Math.min(10, Math.max(-10, (x / 320) * 20 - 10)));
    this.toneY = Math.round(Math.min(10, Math.max(-10, 10 - (y / 230) * 20)));
    this.applyEq();
    if (save) {
      this.persistStore();
    }
  }

  private bandHz(index: number): string {
    const labels = ['60', '150', '400', '1k', '2.5k', '6k', '14k'];
    return index >= 0 && index < labels.length ? labels[index] : '';
  }

  private presetNames(): Array<string> {
    return ['Flat', 'Acoustic', 'Bass boost', 'Bass cut', 'Vocal', 'Treble boost', 'Treble cut', 'Loudness', 'Spoken word'];
  }

  private choosePreset(name: string): void {
    this.eqPreset = name;
    this.eqBands = this.presetCurve(name);
    this.sheet = '';
    this.persistStore();
    this.applyEq();
  }

  private presetCurve(name: string): Array<number> {
    if (name === 'Acoustic') {
      return [4, 3, 1, 0, 2, 3, 2];
    }
    if (name === 'Bass boost') {
      return [6, 5, 3, 1, 0, 0, 0];
    }
    if (name === 'Bass cut') {
      return [-6, -4, -2, 0, 0, 0, 0];
    }
    if (name === 'Vocal') {
      return [-2, -1, 2, 4, 3, 1, 0];
    }
    if (name === 'Treble boost') {
      return [0, 0, 0, 1, 3, 5, 4];
    }
    if (name === 'Treble cut') {
      return [0, 0, 0, -1, -3, -5, -4];
    }
    if (name === 'Loudness') {
      return [5, 3, 0, -1, 0, 2, 4];
    }
    if (name === 'Spoken word') {
      return [-3, -2, 1, 4, 3, 1, -2];
    }
    return [0, 0, 0, 0, 0, 0, 0];
  }

  private setBand(index: number, value: number): void {
    if (index < 0 || index >= this.eqBands.length) {
      return;
    }
    const next: Array<number> = [];
    for (let i = 0; i < this.eqBands.length; i++) {
      next.push(i === index ? value : this.eqBands[i]);
    }
    this.eqBands = next;
    this.eqPreset = '';
    this.persistStore();
    this.applyEq();
  }

  private activeGains(): Array<number> {
    if (!this.eqOn) {
      return [0, 0, 0, 0, 0, 0, 0];
    }
    if (this.eqMode === 'dynamic') {
      const tilt = this.toneX;
      const presence = this.toneY;
      const width = this.eqWidth === 'focused' ? 1 : 0.6;
      return [
        -tilt * 0.6 * width,
        -tilt * 0.35 * width,
        presence * 0.2,
        presence * 0.7 * width,
        presence * 0.4,
        tilt * 0.4 * width,
        tilt * 0.7 * width
      ];
    }
    return this.eqBands;
  }

  private wantsGraph(): boolean {
    return this.eqOn;
  }

  private onAppVisibility(): void {
    if (AppVisibility.hidden) {
      this.soundToPlayer();
      return;
    }
    if (this.webParked && this.eqOn) {
      this.webParked = false;
      this.applyEq();
    }
  }

  private soundToPlayer(): void {
    if (!this.eqHolding || !this.wantSound) {
      return;
    }
    this.webParked = true;
    if (this.audioWebReady) {
      this.audioWeb.runJavaScript('var a=document.getElementById("a");if(a)a.pause();');
    }
    const av = this.player;
    if (av === null) {
      return;
    }
    try {
      av.seek(this.positionMs);
      av.play();
    } catch (_e) {
    }
  }

  private applyEq(): void {
    if (!this.wantsGraph()) {
      this.stopEqWeb(true);
      this.applyEffect();
      return;
    }
    const gains = this.activeGains();
    if (this.eqOn) {
      let sum = 0;
      for (let i = 0; i < gains.length; i++) {
        sum += gains[i];
      }
      this.pushLoudness(Math.min(12, Math.max(-12, sum / gains.length)));
    }
    if (this.eqPage === 0) {
      this.armEq();
    } else {
      this.pushEqGraph(false);
    }
  }

  private songFile(): string {
    if (this.playingPath.length > 0) {
      return this.playingPath;
    }
    const dir = this.cacheDir();
    return dir.length > 0 ? `${dir}/bitchord-now.mp4` : '';
  }

  private armEq(): void {
    if (!this.wantsGraph() || !this.audioWebReady) {
      return;
    }
    const path = this.songFile();
    if (path.length === 0) {
      return;
    }
    try {
      fileIo.statSync(path);
    } catch (_e) {
      return;
    }
    if (this.eqFd < 0) {
      try {
        this.eqFd = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY).fd;
      } catch (_e) {
        return;
      }
    }
    const av = this.player;
    if (av !== null && !this.eqHolding) {
      try {
        av.pause();
      } catch (_e) {
      }
    }
    this.eqHolding = true;
    if (this.eqPage === 0) {
      this.eqPage = 1;
      const html = `<!DOCTYPE html><html><body><audio id="a" autoplay></audio><script>
var a=document.getElementById('a');
var ctx=new (window.AudioContext||window.webkitAudioContext)();
var src=ctx.createMediaElementSource(a);
var freq=[60,150,400,1000,2500,6000,14000];
var filters=[];
var head=src;
for(var i=0;i<freq.length;i++){
  var b=ctx.createBiquadFilter();
  b.type='peaking';
  b.frequency.value=freq[i];
  b.Q.value=0.8;
  b.gain.value=0;
  head.connect(b);
  head=b;
  filters.push(b);
}
var split=ctx.createChannelSplitter(2);
var merge=ctx.createChannelMerger(2);
var delayL=ctx.createDelay(0.05);
var delayR=ctx.createDelay(0.05);
var gainL=ctx.createGain();
var gainR=ctx.createGain();
var crossL=ctx.createGain();
var crossR=ctx.createGain();
delayL.delayTime.value=0;
delayR.delayTime.value=0;
gainL.gain.value=1;
gainR.gain.value=1;
crossL.gain.value=0;
crossR.gain.value=0;
head.connect(split);
split.connect(delayL,0);
split.connect(delayR,1);
delayL.connect(gainL);
delayR.connect(gainR);
gainL.connect(merge,0,0);
gainR.connect(merge,0,1);
delayL.connect(crossR);
delayR.connect(crossL);
crossR.connect(merge,0,1);
crossL.connect(merge,0,0);
merge.connect(ctx.destination);
window.bcSpace=function(on){
  if(!on){
    delayL.delayTime.value=0;delayR.delayTime.value=0;
    crossL.gain.value=0;crossR.gain.value=0;
    gainL.gain.value=1;gainR.gain.value=1;
    return;
  }
  delayL.delayTime.value=0.001;
  delayR.delayTime.value=0.013;
  crossL.gain.value=0.32;
  crossR.gain.value=0.2;
  gainL.gain.value=0.9;
  gainR.gain.value=0.9;
};
window.bcEq=function(gains,q){
  for(var i=0;i<filters.length;i++){filters[i].gain.value=gains[i]||0;filters[i].Q.value=q;}
  if(ctx.state==='suspended'&&ctx.resume){ctx.resume();}
};
window.bcSpace(${this.spatialOn ? 'true' : 'false'});
a.onerror=function(){a.setAttribute('data-state','bad');};
a.onplaying=function(){a.setAttribute('data-state','ok');};
a.src='https://bitchord.eq/now.mp4';
a.currentTime=${this.positionMs / 1000};
var play=a.play();
if(play&&play.catch){play.catch(function(){});}
</script></body></html>`;
      try {
        this.audioWeb.loadData(html, 'text/html', 'UTF-8', 'https://bitchord.eq/');
      } catch (_e) {
        this.stopEqWeb(true);
      }
    }
  }

  private pushEqGraph(seek: boolean): void {
    if (!this.eqHolding || this.eqInjected !== this.eqPage) {
      return;
    }
    const gains = this.activeGains();
    const q = this.eqWidth === 'focused' ? 1.6 : 0.7;
    const parts: Array<string> = [];
    for (let i = 0; i < gains.length; i++) {
      parts.push(`${Math.round(gains[i] * 10) / 10}`);
    }
    const at = seek ? `var a=document.getElementById('a');if(a){a.currentTime=${this.positionMs / 1000};}` : '';
    const space = this.spatialOn ? 'true' : 'false';
    this.audioWeb.runJavaScript(`if(window.bcEq){window.bcEq([${parts.join(',')}],${q});}if(window.bcSpace){window.bcSpace(${space});}${at}`);
  }

  private stopEqWeb(resume: boolean): void {
    const was = this.eqHolding;
    this.eqHolding = false;
    this.webParked = false;
    this.eqPage = 0;
    this.eqInjected = 0;
    if (this.eqFd >= 0) {
      try {
        fileIo.closeSync(this.eqFd);
      } catch (_e) {
      }
      this.eqFd = -1;
    }
    if (this.audioWebReady) {
      this.audioWeb.runJavaScript('var a=document.getElementById("a");if(a){a.pause();a.removeAttribute("src");}');
    }
    if (was && resume) {
      const av = this.player;
      if (av !== null) {
        try {
          av.seek(this.positionMs);
          av.setVolume(this.playVolume);
          if (this.wantSound) {
            av.play();
          }
        } catch (_e) {
        }
      }
      this.pushLoudness(this.loudnessOn ? this.loudnessDb : 0);
    }
  }

  private eqFile(event: OnInterceptRequestEvent): WebResourceResponse | null {
    let url = '';
    try {
      url = event.request.getRequestUrl();
    } catch (_e) {
      return null;
    }
    if (url.indexOf('bitchord.eq/now.mp4') < 0 || this.eqFd < 0) {
      return null;
    }
    const response = new WebResourceResponse();
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseMimeType('video/mp4');
    response.setResponseData(this.eqFd);
    return response;
  }

  private pollEq(): void {
    if (!this.eqHolding || !this.audioWebReady || this.webPollBusy || this.scrubbing) {
      return;
    }
    this.webPollBusy = true;
    this.audioWeb.runJavaScript(
      '(function(){var a=document.getElementById("a");if(!a)return "none";var bad=a.getAttribute("data-state")==="bad";var err=bad?1:0;var dur=isFinite(a.duration)?a.duration:0;return a.currentTime+","+dur+","+(a.paused?0:1)+","+err+","+(a.ended?1:0);})()'
    ).then((raw: string) => {
      this.webPollBusy = false;
      this.readEqReport(raw);
    }).catch(() => {
      this.webPollBusy = false;
    });
  }

  private readEqReport(raw: string): void {
    if (!this.eqHolding) {
      return;
    }
    const text = raw.replace(/"/g, '');
    if (text.length === 0 || text === 'none') {
      return;
    }
    const parts = text.split(',');
    if (parts.length < 5) {
      return;
    }
    if (Number(parts[3]) > 0) {
      this.stopEqWeb(true);
      return;
    }
    const position = Number(parts[0]) * 1000;
    const duration = Number(parts[1]) * 1000;
    if (position >= 0) {
      this.positionMs = position;
    }
    if (duration > 0) {
      this.durationMs = duration;
    }
    this.playing = parts[2] === '1';
    this.syncLyric(this.positionMs);
    this.applyFade(this.positionMs);
    if (parts[4] === '1' && !this.fadeAdvanced) {
      this.fadeAdvanced = true;
      this.advance(true, 1);
    }
  }

  private keptItems(items: Array<ShelfItem>): Array<ShelfItem> {
    if (!this.hidePlayed) {
      return items;
    }
    const out: Array<ShelfItem> = [];
    for (let i = 0; i < items.length; i++) {
      const id = items[i].videoId;
      if (id === null || id.length === 0 || !this.wasPlayed(id)) {
        out.push(items[i]);
      }
    }
    return out;
  }

  private wasPlayed(videoId: string): boolean {
    for (let i = 0; i < this.recentSongs.length; i++) {
      if (this.recentSongs[i].videoId === videoId) {
        return true;
      }
    }
    return false;
  }

  private playShelfItem(shelf: HomeShelf, item: ShelfItem): void {
    let index = 0;
    for (let i = 0; i < shelf.items.length; i++) {
      const id = shelf.items[i].videoId;
      if (id !== null && item.videoId !== null && id === item.videoId) {
        index = i;
        break;
      }
    }
    this.openShelfItem(shelf, index);
  }

  private looksLikeVideo(song: Song): boolean {
    if (song.isVideo) {
      return true;
    }
    const text = song.title.toLowerCase();
    return text.indexOf('official video') >= 0 || text.indexOf('music video') >= 0 ||
      text.indexOf(' mv') >= 0 || text.indexOf('video nhạc') >= 0;
  }

  private replayCurrent(): void {
    if (!this.hasTrack || this.queueIndex < 0 || this.queueIndex >= this.queue.length) {
      return;
    }
    this.playAt(this.queueIndex);
  }

  private async catalogueAudioId(): Promise<string> {
    const song = this.currentSong();
    const query = `${song.title} ${song.artist}`.trim();
    if (query.length === 0) {
      return '';
    }
    try {
      const response = await Innertube.search(query);
      const page = InnertubeParser.parseSearchPage(response, false);
      for (let i = 0; i < page.rows.length; i++) {
        const found = page.rows[i].song;
        if (found !== null && !found.isVideo && found.videoId !== song.videoId) {
          return found.videoId;
        }
      }
    } catch (_e) {
    }
    return '';
  }

  private filesDir(): string {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return '';
    }
    return (host as common.UIAbilityContext).filesDir;
  }

  private downloadFile(videoId: string): string {
    const root = this.filesDir();
    if (root.length === 0 || videoId.length === 0) {
      return '';
    }
    return `${root}/downloads/${videoId}.mp4`;
  }

  private openSaved(videoId: string): number {
    const path = this.downloadFile(videoId);
    if (path.length === 0) {
      return -1;
    }
    try {
      const stat = fileIo.statSync(path);
      if (stat.size < 1024) {
        return -1;
      }
      const opened = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      this.playingPath = path;
      return opened.fd;
    } catch (_e) {
      return -1;
    }
  }

  private keepDownload(source: string): void {
    if (this.wifiOnly && this.onCell()) {
      this.notice = 'k:wifi_blocked';
      return;
    }
    const dest = this.downloadFile(this.audioId);
    if (dest.length === 0) {
      return;
    }
    const folder = dest.substring(0, dest.lastIndexOf('/'));
    try {
      fileIo.mkdirSync(folder);
    } catch (_e) {
    }
    if (this.downloadQuality === 'saver') {
      this.saveSmallCopy(dest, source);
      return;
    }
    if (this.copyPath(source, dest)) {
      this.trimDownloads();
    }
  }

  private async saveSmallCopy(dest: string, fallback: string): Promise<void> {
    try {
      const muxed = await Innertube.resolveMuxedUrl(this.audioId, 160000);
      if (muxed.sources.length === 0) {
        this.copyPath(fallback, dest);
        this.trimDownloads();
        return;
      }
      const first = muxed.sources[0];
      const saved = await this.fetchToFile(first.url, first.userAgent, dest);
      if (!saved) {
        this.copyPath(fallback, dest);
      }
      this.trimDownloads();
    } catch (_e) {
      this.copyPath(fallback, dest);
      this.trimDownloads();
    }
  }

  private copyPath(source: string, dest: string): boolean {
    if (source.length === 0 || dest.length === 0) {
      return false;
    }
    let input = -1;
    let output = -1;
    try {
      input = fileIo.openSync(source, fileIo.OpenMode.READ_ONLY).fd;
      output = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC).fd;
      const buf = new ArrayBuffer(256 * 1024);
      let written = 0;
      while (true) {
        const n = fileIo.readSync(input, buf);
        if (n <= 0) {
          break;
        }
        fileIo.writeSync(output, buf, { length: n });
        written += n;
      }
      return written > 1024;
    } catch (_e) {
      this.notice = 'k:download_skip';
      return false;
    } finally {
      if (input >= 0) {
        try {
          fileIo.closeSync(input);
        } catch (_e) {
        }
      }
      if (output >= 0) {
        try {
          fileIo.closeSync(output);
        } catch (_e) {
        }
      }
    }
  }

  private async fetchToFile(url: string, userAgent: string, dest: string): Promise<boolean> {
    const session = rcp.createSession();
    let output = -1;
    try {
      output = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC).fd;
      let start = 0;
      let total = -1;
      const chunk = 1024 * 1024;
      const headers: rcp.RequestHeaders = { 'user-agent': userAgent };
      while (total < 0 || start < total) {
        const range: rcp.TransferRange = { from: start, to: start + chunk - 1 };
        const request = new rcp.Request(url, 'GET', headers);
        request.transferRange = range;
        const response = await session.fetch(request);
        if (response.statusCode === 416 && start > 0) {
          break;
        }
        if (response.statusCode < 200 || response.statusCode >= 300 || response.body === undefined) {
          return false;
        }
        const bytes = response.body;
        if (bytes.byteLength < 1) {
          break;
        }
        fileIo.writeSync(output, bytes);
        start += bytes.byteLength;
        if (response.statusCode === 200 || bytes.byteLength < chunk) {
          break;
        }
        if (start > 12 * 1024 * 1024) {
          break;
        }
      }
      return start > 1024;
    } catch (_e) {
      return false;
    } finally {
      session.close();
      if (output >= 0) {
        try {
          fileIo.closeSync(output);
        } catch (_e) {
        }
      }
    }
  }

  private trimDownloads(): void {
    const root = this.filesDir();
    if (root.length === 0) {
      return;
    }
    const folder = `${root}/downloads`;
    let names: Array<string> = [];
    try {
      names = fileIo.listFileSync(folder);
    } catch (_e) {
      return;
    }
    let total = 0;
    const rows: Array<string> = [];
    for (let i = 0; i < names.length; i++) {
      const path = `${folder}/${names[i]}`;
      try {
        total += fileIo.statSync(path).size;
        rows.push(path);
      } catch (_e) {
      }
    }
    const limit = this.cacheLimit * 1024 * 1024;
    let index = 0;
    while (total > limit && index < rows.length) {
      const path = rows[index];
      index++;
      if (path === this.playingPath) {
        continue;
      }
      try {
        const size = fileIo.statSync(path).size;
        fileIo.unlinkSync(path);
        total -= size;
      } catch (_e) {
      }
    }
  }

  private async loadGenre(artist: string, token: number): Promise<void> {
    if (!this.lastfm || artist.length === 0) {
      this.genreText = '';
      return;
    }
    const query = encodeURIComponent(`artist:"${artist}"`);
    const found = await this.genreRequest(`https://musicbrainz.org/ws/2/artist/?query=${query}&fmt=json&limit=1`);
    if (token !== this.playToken) {
      return;
    }
    const id = this.jsonText(found, 'id');
    if (id.length === 0) {
      this.genreText = this.t('no_genre');
      return;
    }
    const detail = await this.genreRequest(`https://musicbrainz.org/ws/2/artist/${id}?inc=tags&fmt=json`);
    if (token !== this.playToken) {
      return;
    }
    const tags = this.genreTags(detail);
    this.genreText = tags.length > 0 ? tags : this.t('no_genre');
  }

  private async genreRequest(url: string): Promise<Object | null> {
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'BitChordNEX/1.0 (HarmonyOS)',
          'Accept': 'application/json'
        },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 8000
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return null;
      }
      return JSON.parse(`${response.result}`) as Object;
    } catch (_e) {
      return null;
    } finally {
      client.destroy();
    }
  }

  private jsonText(value: Object | null, key: string): string {
    if (value === null) {
      return '';
    }
    const rec = value as Record<string, Object>;
    const artists = rec['artists'];
    if (Array.isArray(artists) && artists.length > 0) {
      const first = artists[0] as Record<string, Object>;
      const id = first[key];
      return typeof id === 'string' ? id : '';
    }
    const direct = rec[key];
    return typeof direct === 'string' ? direct : '';
  }

  private genreTags(value: Object | null): string {
    if (value === null) {
      return '';
    }
    const rec = value as Record<string, Object>;
    const tags = rec['tags'];
    if (!Array.isArray(tags)) {
      return '';
    }
    const names: Array<string> = [];
    for (let i = 0; i < tags.length && names.length < 3; i++) {
      const row = tags[i] as Record<string, Object>;
      const name = row['name'];
      if (typeof name === 'string' && name.length > 0) {
        names.push(name);
      }
    }
    return names.join(' · ');
  }

  private bitrateCap(): number {
    return this.onCell() ? this.capFor(this.cellQuality) : this.capFor(this.wifiQuality);
  }

  private capFor(mode: string): number {
    return mode === 'saver' ? 160000 : 0;
  }

  private onCell(): boolean {
    try {
      const net = connection.getDefaultNetSync();
      const caps = connection.getNetCapabilitiesSync(net);
      let cell = false;
      let wifi = false;
      for (let i = 0; i < caps.bearerTypes.length; i++) {
        if (caps.bearerTypes[i] === connection.NetBearType.BEARER_CELLULAR) {
          cell = true;
        }
        if (caps.bearerTypes[i] === connection.NetBearType.BEARER_WIFI) {
          wifi = true;
        }
      }
      return cell && !wifi;
    } catch (_e) {
    }
    return false;
  }

  private sourceSummary(): string {
    const parts: Array<string> = [];
    if (this.jioOn) {
      parts.push('JioSaavn');
    }
    parts.push('YouTube Music');
    const extras = this.extensionList();
    if (extras.length > 0) {
      parts.push(`${extras.length} tiện ích`);
    }
    if (this.webdavUrl.length > 0) {
      parts.push('WebDAV');
    }
    return parts.join(' · ');
  }

  private extensionList(): Array<string> {
    const out: Array<string> = [];
    if (this.extensionUrls.length === 0) {
      return out;
    }
    const lines = this.extensionUrls.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length > 0) {
        out.push(line);
      }
    }
    return out;
  }

  private hostOf(url: string): string {
    const trimmed = url.replace(/^https?:\/\//, '');
    const slash = trimmed.indexOf('/');
    return slash >= 0 ? trimmed.substring(0, slash) : trimmed;
  }

  private addExtension(raw: string): void {
    const url = raw.trim();
    if (url.indexOf('http') !== 0) {
      return;
    }
    const list = this.extensionList();
    for (let i = 0; i < list.length; i++) {
      if (list[i] === url) {
        this.sheet = '';
        return;
      }
    }
    list.push(url);
    this.extensionUrls = list.join('\n');
    this.sheet = '';
    this.persistStore();
  }

  private removeExtension(url: string): void {
    const list = this.extensionList();
    const kept: Array<string> = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i] !== url) {
        kept.push(list[i]);
      }
    }
    this.extensionUrls = kept.join('\n');
    this.persistStore();
  }

  private webdavSubtitle(): string {
    if (this.webdavUrl.length === 0) {
      return this.t('webdav_need');
    }
    if (this.webdavState.length > 0) {
      return `${this.shown(this.webdavState)} · ${this.hostOf(this.webdavUrl)}`;
    }
    return this.hostOf(this.webdavUrl);
  }

  private shareSubtitle(): string {
    if (this.shareUri.length === 0) {
      return this.t('share_need');
    }
    return this.t('share_picked');
  }

  private async pickShareFolder(): Promise<void> {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    try {
      const view = new picker.DocumentViewPicker(host as common.UIAbilityContext);
      const opt = new picker.DocumentSelectOptions();
      opt.selectMode = picker.DocumentSelectMode.FOLDER;
      opt.maxSelectNumber = 1;
      const uris = await view.select(opt);
      if (uris.length > 0) {
        this.shareUri = uris[0];
        this.persistStore();
      }
    } catch (_e) {
    }
  }

  private async connectWebdav(): Promise<void> {
    const url = this.draftUrl.trim();
    if (url.indexOf('http') !== 0) {
      this.webdavState = 'k:webdav_http';
      return;
    }
    this.webdavUrl = url;
    this.webdavUser = this.draftUser.trim();
    this.webdavPass = this.draftPass;
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'BitChord' },
        connectTimeout: 8000,
        readTimeout: 8000
      });
      const code = response.responseCode;
      if ((code >= 200 && code < 300) || code === 401 || code === 207) {
        this.webdavState = 'k:webdav_ok';
        this.sheet = '';
      } else {
        this.webdavState = `k:webdav_code|${code}`;
      }
    } catch (_e) {
      this.webdavState = 'k:webdav_fail';
    } finally {
      client.destroy();
    }
    this.persistStore();
  }

  private settingsVisible(title: string, subtitle: string): boolean {
    const query = this.settingsQuery.trim().toLowerCase();
    if (query.length === 0) {
      return true;
    }
    return title.toLowerCase().indexOf(query) >= 0 || subtitle.toLowerCase().indexOf(query) >= 0;
  }

  private regionRows(): Array<string> {
    const packed = [
      'VN|Việt Nam|Vietnam|越南|ベトナム',
      'US|Hoa Kỳ|United States|美国|アメリカ',
      'JP|Nhật Bản|Japan|日本|日本',
      'KR|Hàn Quốc|South Korea|韩国|韓国',
      'TH|Thái Lan|Thailand|泰国|タイ',
      'ID|Indonesia|Indonesia|印度尼西亚|インドネシア',
      'MY|Malaysia|Malaysia|马来西亚|マレーシア',
      'SG|Singapore|Singapore|新加坡|シンガポール',
      'PH|Philippines|Philippines|菲律宾|フィリピン',
      'IN|Ấn Độ|India|印度|インド',
      'TW|Đài Loan|Taiwan|台湾|台湾',
      'HK|Hồng Kông|Hong Kong|香港|香港',
      'GB|Anh|United Kingdom|英国|イギリス',
      'FR|Pháp|France|法国|フランス',
      'DE|Đức|Germany|德国|ドイツ',
      'AU|Úc|Australia|澳大利亚|オーストラリア',
      'CA|Canada|Canada|加拿大|カナダ',
      'BR|Brazil|Brazil|巴西|ブラジル',
      'MX|Mexico|Mexico|墨西哥|メキシコ',
      'ES|Tây Ban Nha|Spain|西班牙|スペイン',
      'IT|Ý|Italy|意大利|イタリア',
      'RU|Nga|Russia|俄罗斯|ロシア',
      'TR|Thổ Nhĩ Kỳ|Türkiye|土耳其|トルコ',
      'NL|Hà Lan|Netherlands|荷兰|オランダ'
    ];
    let slot = 1;
    if (this.lang === 'en') {
      slot = 2;
    } else if (this.lang === 'zh') {
      slot = 3;
    } else if (this.lang === 'ja') {
      slot = 4;
    }
    const out: Array<string> = [];
    for (let i = 0; i < packed.length; i++) {
      const parts = packed[i].split('|');
      out.push(`${parts[0]}|${parts[slot]}`);
    }
    return out;
  }

  private regionLabel(): string {
    if (this.contentRegion.length !== 2) {
      return this.t('location_auto');
    }
    const rows = this.regionRows();
    for (let i = 0; i < rows.length; i++) {
      const parts = rows[i].split('|');
      if (parts[0] === this.contentRegion) {
        return parts[1];
      }
    }
    return this.contentRegion;
  }

  private languageRegion(): string {
    if (this.lang === 'en') {
      return 'US';
    }
    if (this.lang === 'zh') {
      return 'HK';
    }
    if (this.lang === 'ja') {
      return 'JP';
    }
    return 'VN';
  }

  private regionOk(code: string): boolean {
    const allowed = ['VN', 'US', 'JP', 'KR', 'TH', 'ID', 'MY', 'SG', 'PH', 'IN', 'TW', 'HK', 'GB', 'FR', 'DE', 'AU', 'CA', 'BR', 'MX', 'ES', 'IT', 'RU', 'TR', 'NL'];
    for (let i = 0; i < allowed.length; i++) {
      if (allowed[i] === code) {
        return true;
      }
    }
    return false;
  }

  private pushRegion(): void {
    let code = this.contentRegion.length === 2 ? this.contentRegion.toUpperCase() : this.languageRegion();
    if (!this.regionOk(code)) {
      code = '';
    }
    Innertube.setContentRegion(code);
  }

  private chooseRegion(code: string): void {
    this.contentRegion = code;
    this.pushRegion();
    this.sheet = '';
    this.persistStore();
    this.reloadForRegion();
  }

  private reloadForRegion(): void {
    const refreshExplore = this.exploreLoaded || this.tab === 1;
    this.exploreLoaded = false;
    this.exploreShelves = [];
    this.moods = [];
    this.suggestions = [];
    this.loadHome();
    if (refreshExplore) {
      this.loadExplore();
    }
    const text = this.query.trim();
    if (text.length > 0) {
      this.runSearch();
    } else {
      this.results = [];
      this.searchError = '';
    }
    const fromCatalog = this.browseKey.indexOf('FEmusic_') === 0;
    if (this.screen === 'browse' && fromCatalog) {
      this.screen = 'tabs';
      this.browseKey = '';
      this.browseParams = null;
    } else if (this.screen === 'browse' && this.browseKey.length > 0) {
      this.fetchBrowse(this.browseKey, this.browseParams, this.browseTitle);
    }
  }

  private qualityLabel(mode: string): string {
    return mode === 'saver' ? this.t('saver') : this.t('lossless');
  }

  private t(key: string): string {
    return phrase(this.lang, key);
  }

  private langLabel(): string {
    if (this.langMode === 'system') {
      return this.t('language_system');
    }
    if (this.langMode === 'en') {
      return this.t('language_en');
    }
    if (this.langMode === 'zh') {
      return this.t('language_zh');
    }
    if (this.langMode === 'ja') {
      return this.t('language_ja');
    }
    return this.t('language_vi');
  }

  private langMark(): string {
    if (this.langMode === 'en') {
      return 'EN';
    }
    if (this.langMode === 'vi') {
      return 'VI';
    }
    if (this.langMode === 'zh') {
      return '中文';
    }
    if (this.langMode === 'ja') {
      return '日本語';
    }
    return 'A文';
  }

  private cycleLanguage(): void {
    const order: Array<string> = ['system', 'en', 'vi', 'zh', 'ja'];
    let index = 0;
    for (let i = 0; i < order.length; i++) {
      if (order[i] === this.langMode) {
        index = i;
        break;
      }
    }
    this.chooseLanguage(order[(index + 1) % order.length]);
  }

  private resolveLang(): string {
    let resolved = this.langMode;
    if (this.langMode === 'system') {
      resolved = languageFromTag(i18n.System.getSystemLanguage());
    }
    if (resolved !== 'en' && resolved !== 'vi' && resolved !== 'zh' && resolved !== 'ja') {
      resolved = 'en';
    }
    return resolved;
  }

  private bindInnertubeLanguage(resolved: string): void {
    const hl = resolved === 'zh' ? 'zh-CN' : resolved;
    Innertube.appLanguage = (): string | null => {
      return hl;
    };
  }

  private applySystemLanguage(): void {
    const tag = this.langMode === 'system' ? 'default' : (this.lang === 'zh' ? 'zh-Hans' : this.lang);
    try {
      i18n.System.setAppPreferredLanguage(tag);
    } catch (_e) {
    }
  }

  private applyLanguage(): void {
    const resolved = this.resolveLang();
    this.lang = resolved;
    this.bindInnertubeLanguage(resolved);
    this.applySystemLanguage();
  }

  private chooseLanguage(mode: string): void {
    if (mode !== 'system' && mode !== 'en' && mode !== 'vi' && mode !== 'zh' && mode !== 'ja') {
      return;
    }
    this.langMode = mode;
    const resolved = this.resolveLang();
    this.lang = resolved;
    this.bindInnertubeLanguage(resolved);
    this.applySystemLanguage();
    if (this.contentRegion.length !== 2) {
      this.pushRegion();
      this.reloadForRegion();
    }
    this.persistStoreNow();
  }

  private shown(raw: string): string {
    if (raw.length === 0) {
      return '';
    }
    const bar = raw.indexOf('|');
    const head = bar >= 0 ? raw.substring(0, bar) : raw;
    const arg = bar >= 0 ? raw.substring(bar + 1) : '';
    if (head.indexOf('k:') === 0) {
      return this.t(head.substring(2)).replace('%s', arg);
    }
    return raw;
  }

  private eqBlob(): string {
    const gains: Array<string> = [];
    for (let i = 0; i < this.eqBands.length; i++) {
      gains.push(`${Math.round(this.eqBands[i])}`);
    }
    return [
      this.eqOn ? '1' : '0',
      this.eqMode,
      `${Math.round(this.toneX)}`,
      `${Math.round(this.toneY)}`,
      this.eqWidth,
      this.eqPreset,
      gains.join('~')
    ].join(',');
  }

  private readEqBlob(raw: string): void {
    const parts = raw.split(',');
    if (parts.length < 7) {
      return;
    }
    this.eqOn = parts[0] === '1';
    this.eqMode = parts[1] === 'manual' ? 'manual' : 'dynamic';
    const x = parseInt(parts[2], 10);
    const y = parseInt(parts[3], 10);
    this.toneX = x >= -10 && x <= 10 ? x : 0;
    this.toneY = y >= -10 && y <= 10 ? y : 0;
    this.eqWidth = parts[4] === 'focused' ? 'focused' : 'broad';
    this.eqPreset = parts[5];
    const gains = parts[6].split('~');
    const next: Array<number> = [];
    for (let i = 0; i < 7; i++) {
      const value = i < gains.length ? parseInt(gains[i], 10) : 0;
      next.push(value >= -12 && value <= 12 ? value : 0);
    }
    this.eqBands = next;
  }

  private writeFlags(): string {
    return [
      this.loudnessOn ? '1' : '0',
      this.musicOnly ? '1' : '0',
      `${this.crossfade}`,
      this.automix ? '1' : '0',
      this.skipSilence ? '1' : '0',
      this.spatialOn ? '1' : '0',
      this.hideVolume ? '1' : '0',
      this.hideStatus ? '1' : '0',
      this.hidePlayed ? '1' : '0',
      this.smartAlign ? '1' : '0',
      this.lastfm ? '1' : '0',
      this.themeMode,
      this.downloadQuality,
      this.wifiOnly ? '1' : '0',
      `${this.cacheLimit}`,
      this.langMode,
      '0',
      this.mixPerf,
      this.eqBlob(),
      this.contentRegion,
      this.outsideLyric ? (this.lyricFree ? 'free' : 'island') : 'off'
    ].join('|');
  }

  private applyFlags(raw: string): void {
    const parts = raw.split('|');
    if (parts.length < 15) {
      return;
    }
    this.loudnessOn = parts[0] === '1';
    this.musicOnly = parts[1] === '1';
    const fade = parseInt(parts[2], 10);
    this.crossfade = fade >= 0 ? fade : 0;
    this.automix = parts[3] === '1';
    this.skipSilence = parts[4] === '1';
    this.spatialOn = parts[5] === '1';
    this.hideVolume = parts[6] === '1';
    this.hideStatus = parts[7] === '1';
    this.hidePlayed = parts[8] === '1';
    this.smartAlign = parts[9] === '1';
    this.lastfm = parts[10] === '1';
    this.themeMode = parts[11].length > 0 ? parts[11] : 'dark';
    this.downloadQuality = parts[12] === 'saver' ? 'saver' : 'auto';
    this.wifiOnly = parts[13] === '1';
    const limit = parseInt(parts[14], 10);
    this.cacheLimit = limit >= 128 ? limit : 512;
    if (parts.length > 15) {
      const mode = parts[15];
      if (mode === 'system' || mode === 'en' || mode === 'vi' || mode === 'zh' || mode === 'ja') {
        this.langMode = mode;
      }
    }
    if (parts.length > 17) {
      const perf = parts[17];
      if (perf === 'fast' || perf === 'balanced' || perf === 'quality') {
        this.mixPerf = perf;
      }
    }
    if (parts.length > 18) {
      this.readEqBlob(parts[18]);
    }
    if (parts.length > 19 && parts[19].length === 2) {
      this.contentRegion = parts[19].toUpperCase();
    }
    if (parts.length > 20) {
      if (parts[20] === 'off') {
        this.outsideLyric = false;
        this.lyricFree = false;
      } else if (parts[20] === 'free') {
        this.outsideLyric = true;
        this.lyricFree = true;
      } else {
        this.outsideLyric = true;
        this.lyricFree = false;
      }
    }
    this.applyLanguage();
    this.applyTheme();
  }

  private clearSongCache(): void {
    const dir = this.cacheDir();
    if (dir.length === 0) {
      return;
    }
    try {
      fileIo.unlinkSync(`${dir}/bitchord-now.mp4`);
    } catch (_e) {
    }
    const root = this.filesDir();
    if (root.length > 0) {
      try {
        const names = fileIo.listFileSync(`${root}/downloads`);
        for (let i = 0; i < names.length; i++) {
          fileIo.unlinkSync(`${root}/downloads/${names[i]}`);
        }
      } catch (_e) {
      }
    }
    this.notice = 'k:cache_audio';
  }

  private clearImageCache(): void {
    const dir = this.cacheDir();
    let removed = 0;
    try {
      const names = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const name = names[i];
        if (name.endsWith('.jpg') || name.endsWith('.png') || name.endsWith('.webp')) {
          fileIo.unlinkSync(`${dir}/${name}`);
          removed++;
        }
      }
    } catch (_e) {
    }
    this.notice = removed > 0 ? `k:covers_n|${removed}` : 'k:covers_none';
  }

  private exportData(): void {
    const dir = this.cacheDir();
    if (dir.length === 0) {
      return;
    }
    const path = `${dir}/bitchord-data.json`;
    const body = `{"flags":"${this.writeFlags()}","recent":"${this.packSongs(this.recentSongs).replace(/\n/g, '\\n')}"}`;
    try {
      const opened = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(opened.fd, body);
      fileIo.closeSync(opened.fd);
      this.notice = 'k:export_ok';
    } catch (_e) {
      this.notice = 'k:export_fail';
    }
  }

  private importData(): void {
    const dir = this.cacheDir();
    const path = `${dir}/bitchord-data.json`;
    try {
      const opened = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(opened.fd, buf);
      fileIo.closeSync(opened.fd);
      const text = String.fromCharCode(...new Uint8Array(buf));
      const flags = text.match(/"flags":"([^"]*)"/);
      const recent = text.match(/"recent":"([^"]*)"/);
      if (flags !== null && flags.length > 1) {
        this.applyFlags(flags[1]);
      }
      if (recent !== null && recent.length > 1) {
        this.recentSongs = this.unpackSongs(recent[1].replace(/\\n/g, '\n'));
      }
      this.persistStore();
      this.notice = 'k:import_ok';
    } catch (_e) {
      this.notice = 'k:import_none';
    }
  }

  private cellBadge(): string {
    const label = this.qualityLabel(this.cellQuality);
    return this.onCell() ? `${label} · ${this.t('in_use')}` : label;
  }

  private repeatLabel(): string {
    if (this.repeatMode === 1) {
      return this.t('repeat_queue');
    }
    if (this.repeatMode === 2) {
      return this.t('repeat_one');
    }
    return this.t('off');
  }

  private speedLabel(): string {
    const text = `${this.speed}`;
    return text.indexOf('.') >= 0 ? `${text}×` : `${text}.0×`;
  }

  private sleepLabel(): string {
    if (this.sleepChoice === 1) {
      return this.t('sleep_track');
    }
    if (this.sleepChoice === 2) {
      return this.t('sleep_15');
    }
    if (this.sleepChoice === 3) {
      return this.t('sleep_30');
    }
    if (this.sleepChoice === 4) {
      return this.t('sleep_60');
    }
    return this.t('sleep_off');
  }

  private cycleSpeed(): void {
    const steps: Array<number> = [1, 1.25, 1.5, 2, 0.75];
    let index = 0;
    for (let i = 0; i < steps.length; i++) {
      if (steps[i] === this.speed) {
        index = (i + 1) % steps.length;
      }
    }
    this.speed = steps[index];
    const av = this.player;
    if (av !== null) {
      av.setSpeed(this.speedEnum());
    }
    if (this.webUrl.length > 0) {
      this.audioWeb.runJavaScript(`var a=document.getElementById("a");if(a)a.playbackRate=${this.speed};`);
    }
    this.persistStore();
    this.syncSession(true);
  }

  private cycleSleep(): void {
    this.sleepChoice = (this.sleepChoice + 1) % 5;
    this.stopAfterTrack = this.sleepChoice === 1;
    if (this.sleepChoice === 2) {
      this.sleepDeadline = Date.now() + 15 * 60 * 1000;
    } else if (this.sleepChoice === 3) {
      this.sleepDeadline = Date.now() + 30 * 60 * 1000;
    } else if (this.sleepChoice === 4) {
      this.sleepDeadline = Date.now() + 60 * 60 * 1000;
    } else {
      this.sleepDeadline = 0;
    }
  }

  private speedEnum(): media.PlaybackSpeed {
    if (this.speed <= 0.75) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    }
    if (this.speed <= 1) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    }
    if (this.speed <= 1.25) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    }
    if (this.speed <= 1.5) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    }
    return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
  }

  private loopModeValue(): number {
    if (this.shuffle) {
      return 3;
    }
    if (this.repeatMode === 2) {
      return 1;
    }
    if (this.repeatMode === 1) {
      return 2;
    }
    return 0;
  }

  private applyLoop(mode: avSession.LoopMode): void {
    this.shuffle = mode === avSession.LoopMode.LOOP_MODE_SHUFFLE;
    if (mode === avSession.LoopMode.LOOP_MODE_SINGLE) {
      this.repeatMode = 2;
    } else if (mode === avSession.LoopMode.LOOP_MODE_LIST || mode === avSession.LoopMode.LOOP_MODE_SHUFFLE) {
      this.repeatMode = 1;
    } else {
      this.repeatMode = 0;
    }
    this.persistStore();
  }

  private applySpeed(value: number): void {
    if (value <= 0.8) {
      this.speed = 0.75;
    } else if (value < 1.1) {
      this.speed = 1;
    } else if (value < 1.4) {
      this.speed = 1.25;
    } else if (value < 1.7) {
      this.speed = 1.5;
    } else {
      this.speed = 2;
    }
    const av = this.player;
    if (av !== null) {
      av.setSpeed(this.speedEnum());
    }
    this.persistStore();
    this.syncSession(true);
  }

  private readAppBuild(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName.length > 0) {
        this.appBuild = info.versionName;
      }
    } catch (_err) {
    }
  }

  private openAuthor(): void {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: 'https://facebook.com/nnguyenthemanh'
    };
    (host as common.UIAbilityContext).startAbility(want).catch(() => {
      this.notice = 'facebook.com/nnguyenthemanh';
    });
  }

  private lyricMode(): string {
    if (!this.outsideLyric) {
      return 'off';
    }
    return this.lyricFree ? 'free' : 'island';
  }

  private syncSession(force: boolean): void {
    if (!this.hasTrack) {
      return;
    }
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    const now = new NowPlaying();
    now.assetId = this.trackVideoId;
    now.title = this.trackTitle;
    now.artist = this.trackArtist;
    now.artUri = this.trackArt;
    now.durationMs = this.durationMs;
    now.positionMs = this.positionMs;
    now.playing = this.playing;
    now.favorite = this.favorite;
    now.speed = this.speed;
    now.loopMode = this.loopModeValue();
    this.mediaSession.setLyricMode(this.lyricMode());
    now.lyricBody = this.lyricMode() === 'off' ? '' : this.lyricDocument();
    if (this.lyricIndex >= 0 && this.lyricIndex < this.lyricLines.length) {
      const line = this.lyricLines[this.lyricIndex];
      if (!isGap(line)) {
        now.lyric = line.text;
      }
    }
    const commands = new PlaybackCommands();
    commands.play = (): void => {
      if (!this.playing) {
        this.togglePlay();
      }
    };
    commands.pause = (): void => {
      if (this.playing) {
        this.togglePlay();
      }
    };
    commands.next = (): void => {
      this.skip(1);
    };
    commands.previous = (): void => {
      this.skip(-1);
    };
    commands.seek = (ms: number): void => {
      this.positionMs = ms;
      this.seekTo(ms);
      this.syncLyric(ms);
      this.syncSession(true);
    };
    commands.favorite = (_assetId: string): void => {
      this.favorite = !this.favorite;
      this.syncSession(true);
    };
    commands.loop = (mode: avSession.LoopMode): void => {
      this.applyLoop(mode);
    };
    commands.speed = (value: number): void => {
      this.applySpeed(value);
    };
    this.mediaSession.publish(host as common.UIAbilityContext, commands, now, force);
  }

  private lyricDocument(): string {
    const rows: Array<string> = [];
    for (let i = 0; i < this.lyricLines.length; i++) {
      const text = this.lyricLines[i].text.trim();
      if (text.length === 0) {
        continue;
      }
      const total = Math.max(0, lyricCueMs(this.lyricLines, i));
      const minutes = Math.floor(total / 60000);
      const seconds = Math.floor((total % 60000) / 1000);
      const centis = Math.floor((total % 1000) / 10);
      const mm = minutes < 10 ? `0${minutes}` : `${minutes}`;
      const ss = seconds < 10 ? `0${seconds}` : `${seconds}`;
      const cc = centis < 10 ? `0${centis}` : `${centis}`;
      rows.push(`[${mm}:${ss}.${cc}]${text}`);
    }
    return rows.join('\n');
  }

  private syncLyric(ms: number): void {
    if (!this.syncedOn) {
      return;
    }
    let next = -1;
    for (let i = 0; i < this.lyricLines.length; i++) {
      const line = this.lyricLines[i];
      let cue = line.timeMs;
      if (this.smartAlign) {
        const aligned = lyricCueMs(this.lyricLines, i);
        if (line.alignment === 'end' || Math.abs(aligned - line.timeMs) < 2500) {
          cue = aligned;
        }
      }
      if (!isGap(line) && cue <= ms) {
        next = i;
      }
    }
    if (next !== this.lyricIndex) {
      this.lyricIndex = next;
      this.syncSession(true);
      if (next >= 0) {
        try {
          this.lyricScroller.scrollToIndex(next);
        } catch (_e) {
        }
      }
    }
  }
}
