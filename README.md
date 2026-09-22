# SwitcherGrid

[日本語](#日本語) | [English](#english)

---

## English

An iOS jailbreak tweak (Theos/Logos, rootful) that displays the App
Switcher (multitasking screen) as Apple's own iPad-style grid instead of
the default horizontal carousel, plus two related protection features.

### Grid Switcher

- Forces the App Switcher into Apple's native iPad-style grid layout
  (uses Apple's own `SBAppSwitcherSettings` style switch — no custom
  layout code)
- Swipe down on any card, or tap the always-visible **Clear** button, to
  kill every open app at once — including apps scrolled off-screen — all
  in a single simultaneous pass
- Opening an empty switcher (no running apps) instantly returns to the
  Home Screen
- Grid style changes require a Respring to take effect (a button for this
  is in Settings)

### Kill Guard

- Choose protected apps from Settings (native app picker, via
  [AltList](https://github.com/opa334/AltList))
- Protected apps survive kill-all and the swipe-down-to-kill-all gesture
- A normal single-app swipe-kill **always** still works, even for
  protected apps — an intentional escape valve for when you genuinely
  want to kill something
- Long-press any card in the switcher to toggle its protection on/off
- Killing a protected audio app immediately silences it instead of
  leaving a few seconds of lingering audio

### Stay Foreground

- Keeps protected apps genuinely executing through ordinary
  backgrounding — not just a UI flag: the app never even receives the
  "entered background" notification
- Survives a Respring/`sbreload`, not just a Home button press
- Shares the same protected-apps list as Kill Guard — pick apps once,
  protect them from both killing and backgrounding
- Does **not** survive severe memory pressure (Jetsam) or `backboardd`
  being killed — pair with
  [JetsamBoostDaemon](https://github.com/mikiyan1978/sileo-repo) for
  extra Jetsam resilience

### Requirements

- Rootful jailbreak, iOS 14–16.x
- [AltList](https://github.com/opa334/AltList) (`com.opa334.altlist`)
- PreferenceLoader

### Install

Add `https://mikiyan1978.github.io/sileo-repo/` to Sileo, or build from
source with [Theos](https://theos.dev):

```bash
make package FINALPACKAGE=1
```

---

## 日本語

iOSジェイルブレイク用Tweak（Theos/Logos、rootful環境向け）です。アプリ
スイッチャー（マルチタスク画面）を、デフォルトの横カルーセルではなく
Apple純正のiPad風グリッド表示に変更します。それに加えて、2つの保護機能
も含まれています。

### グリッドスイッチャー

- アプリスイッチャーをApple純正のiPad風グリッドレイアウトに強制変更
  （Apple自身が持つ`SBAppSwitcherSettings`のスタイル切り替えをそのまま
  利用——独自レイアウトコードは一切なし）
- カードを下にスワイプ、または常時表示の**Clear**ボタンをタップすると、
  画面外にスクロールしているアプリも含めて、開いている全アプリを
  **一括かつ同時に**Kill
- 何もない状態でスイッチャーを開くと、自動的にホーム画面に戻る
- グリッドスタイルの変更を反映するにはRespringが必要（設定画面にボタン
  あり）

### Kill Guard

- 設定アプリのネイティブなアプリ選択画面（
  [AltList](https://github.com/opa334/AltList)使用）から保護対象アプリ
  を選択可能
- 保護対象アプリは、全Kill・下スワイプによる全Killから保護される
- 通常の**単体**上スワイプKillは、保護対象アプリであっても**常に**効く
  ——本当にKillしたい時のための意図的な逃げ道
- スイッチャー内のカードを長押しすると、保護のON/OFFを切り替え可能
- 保護対象の音楽アプリをKillした瞬間に即座に音を止める（数秒の余韻を
  防止）

### Stay Foreground

- 保護対象アプリを、通常のバックグラウンド化からも実質的に守る——単なる
  見た目のフラグではなく、アプリ自身が「バックグラウンドに回った」とい
  う通知すら一度も受け取らない
- Respring/`sbreload`も生き延びる（ホームボタンで裏に回すだけでなく）
- Kill Guardと同じ保護対象アプリ一覧を共有——一度選ぶだけで、Killとバッ
  クグラウンド化の両方から保護される
- 深刻なメモリ不足（Jetsam）や`backboardd`自体のKillまでは**防げない**
  ——[JetsamBoostDaemon](https://github.com/mikiyan1978/sileo-repo)と
  併用するとJetsam耐性がさらに向上

### 動作要件

- Rootfulジェイルブレイク、iOS 14〜16.x
- [AltList](https://github.com/opa334/AltList)（`com.opa334.altlist`）
- PreferenceLoader

### インストール

Sileoに`https://mikiyan1978.github.io/sileo-repo/`を追加するか、
[Theos](https://theos.dev)でソースからビルド：

```bash
make package FINALPACKAGE=1
```
