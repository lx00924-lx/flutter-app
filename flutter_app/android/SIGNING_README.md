# Android 签名发布说明

已为您配置好正式签名证书：
- **证书文件**: `android/app/AI.jks`
- **签名配置文件**: `android/key.properties`
  - `keyAlias=key0`
  - `keyPassword=a1261600141`
  - `storePassword=a1261600141`
  - `storeFile=AI.jks`

### 本地 `android/app/build.gradle` 配置参考：
如果在您本地的 `android/app/build.gradle`（或 `build.gradle.kts`）中需要引入该签名，请确认 `android { ... }` 块包含以下逻辑：

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
            keyAlias = keystoreProperties['keyAlias']
            keyPassword = keystoreProperties['keyPassword']
            storeFile = keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword = keystoreProperties['storePassword']
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.release
            minifyEnabled false
            shrinkResources false
        }
    }
}
```
