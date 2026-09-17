# Android 签名发布说明

> ⚠️ **2026 年变更**：签名私钥与口令文件**已从本仓库移除**。
> 原因：`android/key.properties` 里是明文口令、`android/app/AI.jks` 是私钥本体，二者入库等于任何
> clone 本仓库的人都能签出与你正式包同签名、可覆盖安装的 APK。
> 现在这两个文件**只保留在开发者本机**，不再提交、也不会再被 git 跟踪。

## 一、本地恢复签名（每个开发者各自执行一次）

在 `flutter_app/android/` 下放置两个文件（它们已被 `.gitignore` 忽略，不会再进仓库）：

1. **私钥**：`flutter_app/android/app/AI.jks`
2. **签名配置**：`flutter_app/android/key.properties`

```properties
storePassword=你的签名口令
keyPassword=你的签名口令
keyAlias=key0
storeFile=AI.jks
```

> 口令请通过安全渠道获取（密码管理器 / 团队密钥库），不要写进任何会被提交的文件，也不要贴在 issue、聊天记录或 README 里。

## 二、构建行为（`android/app/build.gradle`）

签名逻辑已做兼容处理：**有配置用正式签名，没配置也不会让构建失败**。

```groovy
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

android {
    ...
    signingConfigs {
        release {
            if (keystorePropertiesFile.exists()) {
                keyAlias keystoreProperties['keyAlias']
                keyPassword keystoreProperties['keyPassword']
                storeFile(rootProject.file("app/${keystoreProperties['storeFile']}").exists() ?
                          rootProject.file("app/${keystoreProperties['storeFile']}") :
                          file(keystoreProperties['storeFile']))
                storePassword keystoreProperties['storePassword']
            }
        }
    }

    buildTypes {
        release {
            if (keystorePropertiesFile.exists()) {
                signingConfig signingConfigs.release   // 正式包：AI.jks
            } else {
                signingConfig signingConfigs.debug     // 回退：debug 签名，仅用于本地/CI 自测
            }
            minifyEnabled false
            shrinkResources false
        }
    }
}
```

因此：

| 场景 | 结果 |
| :--- | :--- |
| 本机有 `key.properties` + `AI.jks` | 与从前完全一致，使用 `AI.jks`（alias `key0`）正式签名 |
| 新 clone 仓库、未放签名文件 | 依旧可以 `flutter build apk --release`，但用 debug 签名，**不可用于发布** |

## 三、安全提醒（重要）

旧密钥与口令**已经存在于 git 历史中**（曾被提交并推送到 GitHub）。把它们从当前版本移除并不能让它们从历史里消失——任何拿到历史的人仍然可以取出 `AI.jks` 与口令。

- 若该密钥从未用于对外分发：风险可控，但仍建议按上面的方式仅在本机保留，并考虑清理历史。
- 若该密钥签发的 APK 已对外发布：请**生成一把全新密钥**（旧密钥应视为已泄露；Android 不允许同包名换签名覆盖安装，换签后需卸载重装或用 Play App Signing 的密钥轮换流程）。
- 生成新密钥示例：

```bash
keytool -genkeypair -v -keystore AI.jks -keyalg RSA -keysize 2048 -validity 10000 -alias key0
```
