# Подпись BentoDisk для macOS

В приватном репозитории откройте **Settings → Secrets and variables → Actions → Secrets**. Для нотарификации нужны пять repository secrets.

| Имя | Значение |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Сертификат Developer ID Application вместе с закрытым ключом. Экспортируйте пару из «Связка ключей → Мои сертификаты» в защищённый паролем файл `.p12` и передайте содержимое в Base64. |
| `DEVELOPER_ID_P12_PASSWORD` | Пароль, заданный при экспорте `.p12`. |
| `APPLE_ID` | Email Apple Account с доступом к нотарификации для команды. |
| `APPLE_TEAM_ID` | Десятизначный идентификатор команды из раздела Membership details в Apple Developer. |
| `APPLE_APP_SPECIFIC_PASSWORD` | Отдельный пароль приложения, созданный в Apple Account для BentoDisk. |

Например, команда ниже передаёт сертификат в GitHub Secrets без вывода его содержимого в терминал.

```bash
base64 -i BentoDisk.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --repo Perebevaska/bentodisk
```

Для первой проверки откройте **Actions → Build macOS DMG → Run workflow** и включите **Sign with Developer ID and submit the DMG to Apple**. После принятия образа Apple и проверки билета GitHub сохранит приватный артефакт `BentoDisk-macOS-notarized`.

Чтобы автоматически нотарифицировать каждый тег `v*`, в **Settings → Secrets and variables → Actions → Variables** задайте repository variable `BENTODISK_NOTARIZE_RELEASES` равной `true`. Для сборок ветки `main` по-прежнему используется локальная подпись. На тегах Sparkle подписывает окончательный DMG после прикрепления билета Apple.

[Сертификат Developer ID](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) · [Пароли приложений Apple](https://support.apple.com/ru-ru/102654) · [Нотарификация DMG](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
