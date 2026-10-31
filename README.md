# Memory Bandwidth Bench

單檔 SwiftUI 應用程式，量測 Apple Silicon（及 Intel Mac）的記憶體頻寬。

## 建置與執行

    ./build.sh
    open MemoryBandwidthBench.app

build.sh 會編譯 main.swift、更新 .app bundle 並做 ad-hoc 簽章。需要 Xcode Command Line Tools。

## 測試項目

| 項目 | 說明 |
|---|---|
| 讀取 | 每個執行緒掃描自己那片 buffer，8 路展開 uint64 累加，提高在途請求數 |
| 寫入 | 8 路展開填滿 buffer（會重複寫同一塊，數據可能受快取吸附影響） |
| 寫入(乒乓) | 每次迭代交替寫兩塊 buffer，強迫上一輪髒資料在本輪逐出，較貼近 DRAM 持續寫入 |
| 複製 | memcpy，流量計入讀＋寫雙向位元組 |
| CPU+GPU併發 | CPU 全執行緒掃描的同時，Metal kernel 讓 GPU 一起讀取；合計值最接近整機上限 |

## 原廠規格對照

- App 依 `machdep.cpu.brand_string` 自動匹配內建的晶片規格表（M1～M5 全系，數字取自 Apple 官方技術規格頁），
  在標題列顯示原廠記憶體頻寬，圖表畫橘色虛線基準，結果表格多一欄「達原廠 %」，CSV 匯出附 `official_GBps` 與 `pct_of_official`。
- 同家族不同配置頻寬不同（例如 M5 Max：32 核 GPU＝460 GB/s、40 核 GPU＝614 GB/s）。App 會從 IORegistry 讀取 gpu-core-count 自動判定該機配置並顯示對應數字；讀不到時退回顯示兩個數字。M5 依記憶體容量判定（16GB＝153、24／32GB＝170）。

## 量測注意事項

- 小於 L2 的尺寸（16／64 MB）會被快取吸收，數字遠高於 DRAM 頻寬；要看 DRAM 請用 256 MB 以上。
- 記憶體頻寬受 App Nap、其他 App 負載、溫度影響；程式在測試期間會持有 beginActivity 斷言避免降頻。
- CPU 端讀取受 Little's Law 限制（在途請求數 × 64B ÷ 延遲），單靠 CPU 通常只能吃到理論峰值的 5 成上下；
  CPU＋GPU 併發約可到 75–80%。M1 Pro 的 200 GB/s 是匯流排理論峰值。
- 「峰值」是各次迭代中最好的一次；每次迭代本身已含自動重複（湊滿 20 ms 計時窗）以壓低排程誤差。

## 檔案

- main.swift — 全部程式碼（UI + 量測核心 + Metal kernel）
- build.sh — 建置腳本
- make_dmg.sh — 打包 DMG（拖曳安裝格式）
- tools-icon-render.swift — App icon 渲染腳本（CoreGraphics，產生 icons/icon-A/B/C.png）
- icons/ — 1024×1024 icon 來源圖（App 採用樣式 C）
- MemoryBandwidthBench.app — 建置產物
- MemoryBandwidthBench-<版本>.dmg — 安裝映像
