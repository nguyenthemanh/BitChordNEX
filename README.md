# Music Nex

HarmonyOS NEXT music player. Giao diện trong app: English, Tiếng Việt, 中文, 日本語.

## English

Music Nex is a music player for HarmonyOS NEXT phones, tablets, and 2-in-1 devices. It browses and plays a YouTube Music catalogue after you sign in, and it can use JioSaavn as another audio source. Playback continues in the background and shows the current song on the lock screen and in Control Center.

Synced lyrics, a queue, downloads, and sound options such as crossfade, loudness, and an equalizer are part of the player. The in-app language can follow the system, or you can set it to English, Vietnamese, Chinese, or Japanese.

## 中文

Music Nex 是一款面向 HarmonyOS NEXT 手机、平板和二合一设备的音乐播放器。登录后可以浏览并播放 YouTube Music 曲库，也可以把 JioSaavn 作为另一音源。播放会在后台继续，并在锁屏和控制中心显示当前歌曲。

播放器带有同步歌词、播放队列、下载，以及交叉淡化、响度均衡和均衡器等声音选项。界面语言可以跟随系统，也可以设为英语、越南语、中文或日语。

## 日本語

Music Nex は、HarmonyOS NEXT のスマホ、タブレット、2-in-1 向けの音楽プレーヤーです。ログインすると YouTube Music のカタログを探して再生でき、JioSaavn を別の音源として使えます。再生はバックグラウンドでも続き、ロック画面とコントロールセンターに再生中の曲を表示します。

同期歌詞、再生キュー、ダウンロードに加え、クロスフェード、ラウドネス、イコライザーなどの音設定があります。表示言語はシステムに従うか、英語、ベトナム語、中国語、日本語から選べます。

## Tiếng Việt

Music Nex là trình phát nhạc cho điện thoại, máy tính bảng và máy 2-in-1 chạy HarmonyOS NEXT. Sau khi đăng nhập, app duyệt và phát kho nhạc YouTube Music, và có thể dùng JioSaavn làm nguồn âm thanh khác. Nhạc vẫn phát khi app ở nền, và hiện bài đang nghe trên màn hình khóa cùng Control Center.

Trình phát có lời đồng bộ, hàng đợi, tải xuống, cùng các tùy chọn âm thanh như chuyển bài mượt, chuẩn hóa âm lượng và bộ chỉnh âm. Ngôn ngữ trong app có thể theo hệ thống, hoặc chọn tiếng Anh, tiếng Việt, tiếng Trung, tiếng Nhật.

## Install (HAP)

Ready-to-install package: [`release/MusicNex.hap`](release/MusicNex.hap)

### English
- Download [`MusicNex.hap`](release/MusicNex.hap) from this repository.
- On the phone: enable **Developer options** and **USB debugging**.
- Connect the phone to a PC with [DevEco Studio](https://developer.huawei.com/consumer/en/deveco-studio/) / HarmonyOS command-line tools installed.
- Run: `hdc install release/MusicNex.hap`
- Open Music Nex, sign in, and play.

### 中文
- 从本仓库下载 [`MusicNex.hap`](release/MusicNex.hap)。
- 在手机上开启 **开发人员选项** 和 **USB 调试**。
- 用电脑连接手机，并已安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) / HarmonyOS 命令行工具。
- 执行：`hdc install release/MusicNex.hap`
- 打开 Music Nex，登录后即可播放。

### 日本語
- このリポジトリから [`MusicNex.hap`](release/MusicNex.hap) をダウンロードします。
- 端末で **開発者向けオプション** と **USB デバッグ** を有効にします。
- PC に [DevEco Studio](https://developer.huawei.com/consumer/en/deveco-studio/) / HarmonyOS コマンドラインツールを入れ、端末を接続します。
- 実行：`hdc install release/MusicNex.hap`
- Music Nex を開き、ログインして再生します。

### Tiếng Việt
- Tải [`MusicNex.hap`](release/MusicNex.hap) từ repo này.
- Trên điện thoại: bật **Tùy chọn nhà phát triển** và **USB debugging**.
- Kết nối máy với PC đã cài [DevEco Studio](https://developer.huawei.com/consumer/en/deveco-studio/) / công cụ dòng lệnh HarmonyOS.
- Chạy: `hdc install release/MusicNex.hap`
- Mở Music Nex, đăng nhập và nghe nhạc.

## Build from source

- Install DevEco Studio and the HarmonyOS NEXT SDK.
- Open this project folder, set local signing in Project Structure → Signing Configs (keys stay on your machine).
- Click **Run** to build and install, or rebuild `release/MusicNex.hap` from the signed output.
