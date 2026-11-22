import { common, wantAgent, Want } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class PlaybackCommands {
  play: () => void = (): void => {
  };
  pause: () => void = (): void => {
  };
  next: () => void = (): void => {
  };
  previous: () => void = (): void => {
  };
  seek: (ms: number) => void = (_ms: number): void => {
  };
  favorite: (assetId: string) => void = (_assetId: string): void => {
  };
  loop: (mode: avSession.LoopMode) => void = (_mode: avSession.LoopMode): void => {
  };
  speed: (value: number) => void = (_value: number): void => {
  };
}

export class NowPlaying {
  assetId: string = '';
  title: string = '';
  artist: string = '';
  artUri: string = '';
  durationMs: number = 0;
  positionMs: number = 0;
  playing: boolean = false;
  lyric: string = '';
  lyricBody: string = '';
  favorite: boolean = false;
  speed: number = 1;
  loopMode: number = 0;
}

export class PlaybackSession {
  private session: avSession.AVSession | null = null;
  private context: common.UIAbilityContext | null = null;
  private commands: PlaybackCommands = new PlaybackCommands();
  private backgroundStarted: boolean = false;
  private activated: boolean = false;
  private lastAsset: string = '';
  private lastLyric: string = '';
  private lastLyricBody: string = '';
  private lyricMode: string = 'island';
  private lastArt: string = '';
  private lastTitle: string = '';
  private lastArtist: string = '';
  private lastDuration: number = 0;
  private lastStatePush: number = 0;

  async publish(context: common.UIAbilityContext, commands: PlaybackCommands, now: NowPlaying,
    force: boolean): Promise<void> {
    this.commands = commands;
    this.context = context;
    if (now.assetId.length === 0) {
      return;
    }
    try {
      await this.ensure(context);
      const session = this.session;
      if (session === null) {
        return;
      }
      const metaChanged = force || now.assetId !== this.lastAsset || now.lyric !== this.lastLyric ||
        now.lyricBody !== this.lastLyricBody ||
        now.artUri !== this.lastArt || now.title !== this.lastTitle || now.artist !== this.lastArtist ||
        now.durationMs !== this.lastDuration;
      if (metaChanged) {
        await session.setAVMetadata(this.metadata(now));
        this.lastAsset = now.assetId;
        this.lastLyric = now.lyric;
        this.lastLyricBody = now.lyricBody;
        this.lastArt = now.artUri;
        this.lastTitle = now.title;
        this.lastArtist = now.artist;
        this.lastDuration = now.durationMs;
      }
      const nowMs = Date.now();
      if (force || nowMs - this.lastStatePush > 3000) {
        await session.setAVPlaybackState(this.playback(now));
        this.lastStatePush = nowMs;
      }
      if (!this.activated) {
        await session.activate();
        this.activated = true;
      }
      await this.applyLyricWindow(session);
      await this.startBackground(context);
    } catch (e) {
      const detail = e instanceof Error ? e.message : `${e}`;
      hilog.error(0x0000, 'BitChord', 'session %{public}s', detail.substring(0, 180));
    }
  }

  setLyricMode(mode: string): void {
    if (mode === 'off' || mode === 'free') {
      this.lyricMode = mode;
      return;
    }
    this.lyricMode = 'island';
  }

  async release(): Promise<void> {
    const session = this.session;
    const context = this.context;
    this.session = null;
    this.activated = false;
    this.backgroundStarted = false;
    this.lastAsset = '';
    if (session !== null) {
      try {
        await session.deactivate();
      } catch (_e) {
      }
      try {
        await session.destroy();
      } catch (_e) {
      }
    }
    if (context !== null) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
      } catch (_e) {
      }
    }
  }

  private async ensure(context: common.UIAbilityContext): Promise<void> {
    if (this.session !== null) {
      return;
    }
    const created = await avSession.createAVSession(context, 'BitChord', 'audio');
    this.session = created;
    created.on('play', () => {
      this.commands.play();
    });
    created.on('pause', () => {
      this.commands.pause();
    });
    created.on('playNext', () => {
      this.commands.next();
    });
    created.on('playPrevious', () => {
      this.commands.previous();
    });
    created.on('seek', (time: number) => {
      this.commands.seek(time);
    });
    created.on('toggleFavorite', (assetId: string) => {
      this.commands.favorite(assetId);
    });
    created.on('setLoopMode', (mode: avSession.LoopMode) => {
      this.commands.loop(mode);
    });
    created.on('setSpeed', (value: number) => {
      this.commands.speed(value);
    });
    const controls: Array<avSession.AVMediaCenterControlType> =
      ['playPrevious', 'playNext', 'toggleFavorite'];
    try {
      await created.setMediaCenterControlType(controls);
    } catch (_e) {
    }
    try {
      await created.setBackgroundPlayMode(avSession.BackgroundPlayMode.ENABLE_BACKGROUND_PLAY);
    } catch (_e) {
    }
    const agent = await this.launchAgent(context);
    await created.setLaunchAbility(agent);
  }

  private async launchAgent(context: common.UIAbilityContext) {
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name
    };
    const flags: Array<wantAgent.WantAgentFlags> = [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG];
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: flags
    };
    return await wantAgent.getWantAgent(info);
  }

  private async applyLyricWindow(session: avSession.AVSession): Promise<void> {
    try {
      const supported = await avSession.isDesktopLyricSupported();
      if (!supported || this.lyricMode === 'off') {
        await session.setDesktopLyricVisible(false);
        await session.enableDesktopLyric(false);
        return;
      }
      await session.enableDesktopLyric(true);
      if (this.lyricMode === 'free') {
        await session.setDesktopLyricVisible(true);
        const state: avSession.DesktopLyricState = { isLocked: false };
        await session.setDesktopLyricState(state);
        return;
      }
      await session.setDesktopLyricVisible(false);
      const state: avSession.DesktopLyricState = { isLocked: true };
      await session.setDesktopLyricState(state);
    } catch (e) {
      const detail = e instanceof Error ? e.message : `${e}`;
      hilog.error(0x0000, 'BitChord', 'lyric window %{public}s', detail.substring(0, 160));
    }
  }

  private islandLine(text: string): string {
    const clean = text.replace(/\s+/g, ' ').trim();
    if (clean.length <= 16) {
      return clean;
    }
    return `${clean.substring(0, 15)}...`;
  }

  private async startBackground(context: common.UIAbilityContext): Promise<void> {
    if (this.backgroundStarted) {
      return;
    }
    const agent = await this.launchAgent(context);
    try {
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.backgroundStarted = true;
      return;
    } catch (e) {
      const detail = e instanceof Error ? e.message : `${e}`;
      hilog.error(0x0000, 'BitChord', 'background %{public}s', detail.substring(0, 160));
    }
    try {
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      const modes: Array<backgroundTaskManager.BackgroundTaskMode> = [
        backgroundTaskManager.BackgroundTaskMode.MODE_AUDIO_PLAYBACK
      ];
      request.backgroundTaskModes = modes;
      request.wantAgent = agent;
      request.combinedTaskNotification = false;
      await backgroundTaskManager.startBackgroundRunning(context, request);
      this.backgroundStarted = true;
    } catch (e) {
      const detail = e instanceof Error ? e.message : `${e}`;
      hilog.error(0x0000, 'BitChord', 'background task %{public}s', detail.substring(0, 160));
    }
  }

  private metadata(now: NowPlaying): avSession.AVMetadata {
    const meta: avSession.AVMetadata = {
      assetId: now.assetId
    };
    meta.duration = now.durationMs;
    if (now.artUri.length > 0) {
      meta.mediaImage = now.artUri;
    }
    meta.title = now.title;
    meta.artist = now.artist;
    if (this.lyricMode !== 'off' && now.lyricBody.length > 0) {
      meta.lyric = now.lyricBody;
    }
    if (this.lyricMode !== 'off' && now.lyric.length > 0) {
      meta.singleLyricText = this.lyricMode === 'island' ? this.islandLine(now.lyric) : now.lyric;
    }
    return meta;
  }

  private playback(now: NowPlaying): avSession.AVPlaybackState {
    const state: avSession.AVPlaybackState = {
      state: now.playing ?
        avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE
    };
    const position: avSession.PlaybackPosition = {
      elapsedTime: now.positionMs,
      updateTime: Date.now()
    };
    state.position = position;
    state.duration = now.durationMs;
    state.speed = now.speed;
    state.isFavorite = now.favorite;
    state.loopMode = this.loopMode(now.loopMode);
    return state;
  }

  private loopMode(mode: number): avSession.LoopMode {
    if (mode === 1) {
      return avSession.LoopMode.LOOP_MODE_SINGLE;
    }
    if (mode === 2) {
      return avSession.LoopMode.LOOP_MODE_LIST;
    }
    if (mode === 3) {
      return avSession.LoopMode.LOOP_MODE_SHUFFLE;
    }
    return avSession.LoopMode.LOOP_MODE_SEQUENCE;
  }
}
