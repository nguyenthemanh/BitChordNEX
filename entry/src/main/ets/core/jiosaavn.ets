import { http } from '@kit.NetworkKit';

/** Tìm một URL âm thanh JioSaavn. Chuỗi rỗng nghĩa là không có bản dùng được. */
export async function jioAudioUrl(title: string, artist: string): Promise<string> {
  const query = `${title} ${artist}`.trim();
  if (query.length === 0) {
    return '';
  }
  const endpoint = `https://www.jiosaavn.com/api.php?__call=search.getResults&_format=json&_marker=0&cc=in&n=5&p=1&q=${encodeURIComponent(query)}`;
  return readMediaUrl(endpoint);
}

/** Hỏi máy chủ tiện ích tự lưu. Chấp nhận JSON {"url":"..."} hoặc chuyển hướng tới file nhạc. */
export async function extensionAudioUrl(base: string, title: string, artist: string): Promise<string> {
  const root = base.trim().replace(/\/+$/, '');
  if (root.length === 0) {
    return '';
  }
  const endpoint = `${root}/stream?title=${encodeURIComponent(title)}&artist=${encodeURIComponent(artist)}`;
  return readMediaUrl(endpoint);
}

async function readMediaUrl(endpoint: string): Promise<string> {
  const client = http.createHttp();
  try {
    const response = await client.request(endpoint, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'Mozilla/5.0',
        'Accept': 'application/json, audio/*'
      },
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 4000,
      readTimeout: 5000
    });
    if (response.responseCode < 200 || response.responseCode >= 300) {
      return '';
    }
    const type = headerValue(response.header, 'content-type');
    if (type.indexOf('audio/') === 0 || type.indexOf('video/') === 0) {
      return endpoint;
    }
    return mediaFromBody(`${response.result}`);
  } catch (_e) {
    return '';
  } finally {
    client.destroy();
  }
}

function headerValue(headers: Object, name: string): string {
  const rec = headers as Record<string, Object>;
  const keys = Object.keys(rec);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() === name) {
      return `${rec[keys[i]]}`.toLowerCase();
    }
  }
  return '';
}

function mediaFromBody(raw: string): string {
  const urlKey = raw.indexOf('"url"');
  const fromJson = urlKey >= 0 ? quotedAfter(raw, urlKey) : '';
  if (fromJson.indexOf('http') === 0) {
    return cleanUrl(fromJson);
  }
  const direct = firstKey(raw, '"media_url"');
  if (direct.indexOf('http') === 0) {
    return cleanUrl(direct);
  }
  const preview = firstKey(raw, '"media_preview_url"');
  if (preview.indexOf('http') === 0) {
    return cleanUrl(preview);
  }
  return '';
}

function firstKey(raw: string, key: string): string {
  const at = raw.indexOf(key);
  if (at < 0) {
    return '';
  }
  return quotedAfter(raw, at);
}

function quotedAfter(raw: string, from: number): string {
  const quote = raw.indexOf('"', raw.indexOf(':', from) + 1);
  if (quote < 0) {
    return '';
  }
  const end = raw.indexOf('"', quote + 1);
  if (end < 0) {
    return '';
  }
  return raw.substring(quote + 1, end);
}

function cleanUrl(value: string): string {
  return value.replace(/\\\//g, '/').replace(/\\u0026/g, '&');
}
