# GitHub: привязка один раз

Репозиторий готов к публикации: 28 файлов, ~2.8 МБ, истории и мусора нет.

## 1. Создай пустой репозиторий

GitHub → New repository → имя `zc_lvs_support` → **Private** (или Public) →
**НЕ** добавляй README / .gitignore / license (они уже есть).

## 2. Создай токен (один раз)

GitHub → Settings → Developer settings → Personal access tokens →
**Fine-grained tokens** → Generate:
- Repository access: Only select repositories → `zc_lvs_support`
- Permissions → Contents: **Read and write**

Скопируй токен (виден один раз).

## 3. Привяжи и запушь

```bash
cd C:/Users/lazyg/OneDrive/Desktop/zc_mod/zc_lvs_support
git remote add origin https://github.com/<ты>/zc_lvs_support.git
git push -u origin master
```

При запросе логина: user = `<ты>`, password = **токен** (не пароль GitHub).
Windows запомнит его в диспетчере учётных данных — второй раз не спросит.

## 4. Релизы (чтобы «не все версии», а только релизы)

Обычные коммиты живут в мастере, но на главной странице репозитория виден
только последний релиз, а не вся история коммитов. Версия ставится тегом:

```bash
git tag v4.2.0
git push origin v4.2.0
```

GitHub → Releases → Draft a new release → choose tag `v4.2.0` →
Publish. Хочешь — приложи .gma в Release assets.

Правило дальше простое: **тег = релиз**. Обычные коммиты в мастер
ничего не публикуют.

## Что уже настроено

- `.gitattributes` — LF в репозитории, CRLF локально не ломает Lua.
- `.gitignore` — `.gma`, `CODEX_HISTORY.md`, `.claude/worktrees/`.
- `git status` чистый, кроме неизменённых `CLAUDE.md`/`TODO.md`.
