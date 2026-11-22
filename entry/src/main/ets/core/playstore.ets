import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class StoredPlay {
  repeatMode: number = 0;
  shuffle: boolean = false;
  speed: number = 1;
  wifi: string = 'auto';
  cell: string = 'auto';
  recent: string = '';
  cookie: string = '';
  effectOn: boolean = true;
  fullArt: boolean = false;
  syncedOn: boolean = true;
  statsOn: boolean = false;
  jioOn: boolean = true;
  extensions: string = '';
  webdavUrl: string = '';
  webdavUser: string = '';
  webdavPass: string = '';
  shareUri: string = '';
  flags: string = '';
}

export class PlayStore {
  static async load(context: common.UIAbilityContext): Promise<StoredPlay> {
    const out = new StoredPlay();
    try {
      const pref = await preferences.getPreferences(context, 'bitchord');
      out.repeatMode = PlayStore.num(await pref.get('repeat', 0), 0);
      out.shuffle = PlayStore.bool(await pref.get('shuffle', false));
      out.speed = PlayStore.num(await pref.get('speed', 1), 1);
      out.wifi = PlayStore.text(await pref.get('wifi', 'auto'), 'auto');
      out.cell = PlayStore.text(await pref.get('cell', 'auto'), 'auto');
      out.recent = PlayStore.text(await pref.get('recent', ''), '');
      out.cookie = PlayStore.text(await pref.get('cookie', ''), '');
      out.effectOn = PlayStore.bool(await pref.get('effect', true));
      out.fullArt = PlayStore.bool(await pref.get('fullArt', false));
      out.syncedOn = PlayStore.bool(await pref.get('synced', true));
      out.statsOn = PlayStore.bool(await pref.get('stats', false));
      out.jioOn = PlayStore.boolOr(await pref.get('jio', true), true);
      out.extensions = PlayStore.text(await pref.get('extensions', ''), '');
      out.webdavUrl = PlayStore.text(await pref.get('webdavUrl', ''), '');
      out.webdavUser = PlayStore.text(await pref.get('webdavUser', ''), '');
      out.webdavPass = PlayStore.text(await pref.get('webdavPass', ''), '');
      out.shareUri = PlayStore.text(await pref.get('shareUri', ''), '');
      out.flags = PlayStore.text(await pref.get('flags', ''), '');
    } catch (_e) {
    }
    return out;
  }

  static async save(context: common.UIAbilityContext, data: StoredPlay): Promise<void> {
    try {
      const pref = await preferences.getPreferences(context, 'bitchord');
      await pref.put('repeat', data.repeatMode);
      await pref.put('shuffle', data.shuffle);
      await pref.put('speed', data.speed);
      await pref.put('wifi', data.wifi);
      await pref.put('cell', data.cell);
      await pref.put('recent', data.recent);
      await pref.put('cookie', data.cookie);
      await pref.put('effect', data.effectOn);
      await pref.put('fullArt', data.fullArt);
      await pref.put('synced', data.syncedOn);
      await pref.put('stats', data.statsOn);
      await pref.put('jio', data.jioOn);
      await pref.put('extensions', data.extensions);
      await pref.put('webdavUrl', data.webdavUrl);
      await pref.put('webdavUser', data.webdavUser);
      await pref.put('webdavPass', data.webdavPass);
      await pref.put('shareUri', data.shareUri);
      await pref.put('flags', data.flags);
      await pref.flush();
    } catch (_e) {
    }
  }

  private static num(value: preferences.ValueType, fallback: number): number {
    if (typeof value === 'number') {
      return value;
    }
    return fallback;
  }

  private static bool(value: preferences.ValueType): boolean {
    return PlayStore.boolOr(value, false);
  }

  private static boolOr(value: preferences.ValueType, fallback: boolean): boolean {
    if (typeof value === 'boolean') {
      return value;
    }
    return fallback;
  }

  private static text(value: preferences.ValueType, fallback: string): string {
    if (typeof value === 'string') {
      return value;
    }
    return fallback;
  }
}
