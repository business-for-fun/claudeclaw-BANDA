# GCP Infrastructure Audit Report
**Date:** 2026-04-06
**Auditor:** Olaf (Infrastructure Engineer)
**Authorization:** boss@business-for-fun.com

## 🎯 Executive Summary

**Общее количество проектов:** 12
**Активных проектов:** 4
**VM найдено:** 4 (все в одном проекте)
**Организаций:** 1
**Биллинг аккаунтов:** 3 (2 активных)

## 📊 Detailed Project Analysis

### 🟢 АКТИВНЫЕ ПРОЕКТЫ (4)

#### 1. business-for-fun-landing (557769238075)
- **Назначение:** R4G Firebase Hosting
- **Статус:** ✅ АКТИВНЫЙ
- **API:** 48+ включены (Firebase, App Engine, BigQuery, Cloud Functions, Cloud Run)
- **VM:** ❌ Compute Engine не включен
- **Service Accounts:** 4
  - App Engine default service account
  - Default compute service account (557769238075-compute@developer.gserviceaccount.com)
  - GitHub Actions (github-action-1157247639@business-for-fun-landing.iam.gserviceaccount.com)
  - firebase-adminsdk (firebase-adminsdk-fbsvc@business-for-fun-landing.iam.gserviceaccount.com)
- **Использование:** Firebase Hosting + GitHub CI/CD
- **Рекомендация:** 🟢 Оставить

#### 2. n8n-instance-475317 / "n8n for me" (990449935733)
- **Назначение:** ВСЕ VM инфраструктуры
- **Статус:** ✅ АКТИВНЫЙ
- **API:** 34+ включены (Compute Engine, Cloud Asset, Monitoring)
- **VM:** ✅ 4 АКТИВНЫХ
  - `moltbot-personal-new` (10.128.0.8 / 34.173.135.235) - OpenClaw, Supabase, BANDA
  - `n8n-client-1` (10.128.0.5 / 136.112.242.139) - R4G n8n
  - `n8n-limo-1-clone` (10.128.0.7 / 136.116.141.219) - LIMO n8n
  - `n8n-instance-for-me` (10.128.0.3 / 35.209.77.223) - FAM n8n
- **Service Accounts:** 1 (Default compute)
- **Использование:** Основная production инфраструктура
- **Рекомендация:** 🟢 КРИТИЧЕСКИ ВАЖЕН

#### 3. r4g-n8n (334308167793)
- **Назначение:** R4G n8n backend (без VM)
- **Статус:** ✅ АКТИВНЫЙ
- **API:** 23 включены (BigQuery, Sheets, Drive, Storage)
- **VM:** ❌ Compute Engine не включен
- **Service Accounts:** 0
- **Использование:** API доступы для R4G workflows
- **Рекомендация:** 🟢 Оставить

#### 4. limo-n8n (844504431868)
- **Назначение:** LIMO n8n backend (без VM)
- **Статус:** ✅ АКТИВНЫЙ
- **API:** 25+ включены (BigQuery, Gmail, Calendar, Drive, Sheets)
- **VM:** ❌ Compute Engine не включен
- **Service Accounts:** 0
- **Использование:** API доступы для LIMO workflows
- **Рекомендация:** 🟢 Оставить

### 🟡 ПУСТЫЕ/МИНИМАЛЬНЫЕ ПРОЕКТЫ (2)

#### 5. meta-century-487321-e1 / "My First Project" (147088475138)
- **Назначение:** Неизвестно (возможно Google Workspace)
- **Статус:** 🟡 ПУСТОЙ
- **API:** 20 стандартных (BigQuery, Storage, Logging)
- **VM:** ❌ Compute Engine не включен
- **Service Accounts:** 0
- **Использование:** Минимальное
- **Рекомендация:** ❓ Выяснить назначение или удалить

#### 6. gen-lang-client-0000493919 / "Default Gemini Project" (811043085821)
- **Назначение:** Gemini AI
- **Статус:** 🟡 МИНИМАЛЬНЫЙ
- **API:** 1 включен
- **VM:** Неизвестно (нет Compute API)
- **Service Accounts:** Неизвестно
- **Использование:** Минимальное
- **Рекомендация:** ❓ Проверить использование Gemini

### 🔴 НЕДОСТУПНЫЕ ПРОЕКТЫ (6)

**Статус:** ❌ Permission denied для boss@business-for-fun.com

| Project ID | Name | Number | Status |
|---|---|---|---|
| gen-lang-client-0100619906 | Iryna Project | 885503528606 | ❌ No access |
| gen-lang-client-0587960856 | Iryna Ivo Project | 624313286815 | ❌ No access |
| gen-lang-client-0591643255 | Default Gemini Project | 314092248798 | ❌ No access |
| gen-lang-client-0829122317 | Default Gemini Project | 218398492599 | ❌ No access |
| gen-lang-client-0847432113 | Iryna Project | 570560438027 | ❌ No access |
| gen-lang-client-0987731973 | Iryna Project | 210877873586 | ❌ No access |

**Рекомендация:** 🔴 Проверить права доступа или удалить

## 🏢 Organization & Billing

### Organization
- **Name:** business-for-fun.com
- **ID:** 180434074994
- **Customer ID:** C03m49q8z
- **Status:** ✅ Active

### Billing Accounts
| Account ID | Name | Status |
|---|---|---|
| 010CCB-C1C91C-272018 | My Billing Account 1 | ✅ Open |
| 011080-E58DC2-71DBE8 | My Billing Account 2 | ✅ Open |
| 0182ED-4C31B0-748270 | My Billing Account | ❌ Closed |

## 🔥 Infrastructure Mapping

### Production VM (все в n8n-instance-475317)
| Сервер | Internal IP | External IP | Роль | Status |
|---|---|---|---|---|
| moltbot-personal-new | 10.128.0.8 | 34.173.135.235 | OpenClaw, Supabase, BANDA | ✅ RUNNING |
| n8n-client-1 | 10.128.0.5 | 136.112.242.139 | n8n (R4G) | ✅ RUNNING |
| n8n-limo-1-clone | 10.128.0.7 | 136.116.141.219 | n8n (LIMO) | ✅ RUNNING |
| n8n-instance-for-me | 10.128.0.3 | 35.209.77.223 | n8n (FAM) | ✅ RUNNING |

**⚠️ КРИТИЧЕСКОЕ ЗАМЕЧАНИЕ:** Вся production инфраструктура находится в одном проекте!

### Firebase Hosting
- **Проект:** business-for-fun-landing
- **Status:** ✅ Активен с GitHub Actions CI/CD

## 📋 RECOMMENDATIONS

### 🚨 КРИТИЧЕСКИЕ
1. **Single Point of Failure:** Все VM в одном проекте `n8n-instance-475317`
2. **Backup Strategy:** Убедиться что есть backup VM и данных

### 🟡 ОПТИМИЗАЦИЯ
1. **Очистка недоступных проектов:** 6 Iryna/Gemini проектов без доступа
2. **Проверить meta-century-487321-e1:** Выяснить назначение или удалить
3. **Billing optimization:** Проверить расходы по закрытому аккаунту

### 🟢 АРХИТЕКТУРНЫЕ
1. **VM distribution:** Рассмотреть распределение VM по разным проектам для изоляции
2. **Service accounts:** Создать специализированные SA для разных сервисов

## 📈 Resource Usage Summary

| Project Type | Count | VM | Active API | Service Accounts |
|---|---|---|---|---|
| 🟢 Production | 4 | 4 | 130+ | 5 |
| 🟡 Minimal | 2 | 0 | 21 | 0 |
| 🔴 No Access | 6 | ? | ? | ? |
| **TOTAL** | **12** | **4** | **151+** | **5** |

---
*Report generated by Olaf Infrastructure Engineer*
*Next audit recommended: Monthly*