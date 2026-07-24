#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Add two final sections to existing VPN report:
1. Split Tunneling section
2. Costs & GTM section
"""

from docx import Document
from docx.shared import Pt, RGBColor, Cm
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

def set_cell_background(cell, fill_color):
    shading_elm = OxmlElement('w:shd')
    shading_elm.set(qn('w:fill'), fill_color)
    cell._element.get_or_add_tcPr().append(shading_elm)

def table_from_data(doc, headers, data, cols=None):
    if cols is None:
        cols = len(headers)
    table = doc.add_table(rows=len(data) + 1, cols=cols)
    table.style = 'Light Grid Accent 1'
    
    for i, header in enumerate(headers):
        cell = table.rows[0].cells[i]
        cell.text = header
        set_cell_background(cell, 'DEEAF1')
        if cell.paragraphs[0].runs:
            cell.paragraphs[0].runs[0].font.bold = True
    
    for row_idx, row_data in enumerate(data, start=1):
        for col_idx, text in enumerate(row_data):
            table.rows[row_idx].cells[col_idx].text = str(text)
            for paragraph in table.rows[row_idx].cells[col_idx].paragraphs:
                for run in paragraph.runs:
                    run.font.size = Pt(9)
                    run.font.name = 'Calibri'
    
    return table

# Open existing document
doc = Document('/home/alexey/banda/projects/r4g/docs/vpn-analysis-report.docx')

# ===== SECTION: SPLIT TUNNELING =====
doc.add_page_break()
split_title = doc.add_heading('РАЗДЕЛ 9: Избирательная фильтрация трафика (Split Tunneling)', level=1)
split_title.style.font.name = 'Calibri'

p = doc.add_paragraph()
p.add_run("Автор: ").font.bold = True
p.add_run("Gale (Technical Research)\nДата: 30 мая 2026")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

# Split Tunneling - Overview
doc.add_heading('1. Как работает маршрутизация в Xray-core', level=2).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("Xray-core имеет встроенную систему маршрутизации (Routing System) — движок классификации трафика, "
          "который оценивает входящие соединения по настраиваемым правилам и направляет трафик к нужным обработчикам.")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

routing_data = [
    ('Whitelist (selective proxy)', 'Только заблокированные домены → VPN', 'Экономия трафика, скорость, минимальное влияние'),
    ('Blacklist (full tunnel minus exceptions)', 'Всё → VPN, кроме локального/банковского', 'Максимальная приватность'),
]
table_from_data(doc, ['Режим', 'Логика', 'Для кого'], routing_data, cols=3)

p = doc.add_paragraph()
p.add_run("Рекомендация для РФ: ").font.bold = True
p.add_run("Whitelist — пользователи хотят быстрый интернет + доступ к заблокированному.")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

# GeoSite/GeoIP
doc.add_heading('2. GeoSite.dat и GeoIP.dat', level=2).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("geosite.dat — бинарный файл с категоризованными списками доменов: ")
p.add_run("geosite:google (Google), geosite:youtube (YouTube), geosite:ru-blocked (заблокированные в РФ), "
          "geosite:category-ads-all (реклама).\n")
p.add_run("geoip.dat — IP-диапазоны по странам: geoip:ru, geoip:private, geoip:cn")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

geo_data = [
    ('runetfreedom/russia-blocked-geosite', 'antifilter + refilter + community', 'Обновление каждые 6 часов', '700K+ доменов'),
    ('runetfreedom/russia-blocked-geoip', 'РКН IP dump', 'Обновление каждые 6 часов', '~100K ranges'),
    ('Re-filter-lists', 'Кураторский список', 'Ежедневно', '~30K'),
    ('antifilter.download', 'Прямой dump РКН', 'Непрерывно', '700K+'),
]
table_from_data(doc, ['Проект', 'Источник', 'Обновление', 'Домены'], geo_data, cols=4)

# Happ support
doc.add_heading('3. Поддержка в Happ', level=2).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("Happ ПОЛНОСТЬЮ поддерживает split tunneling. ").font.bold = True
p.add_run("Возможности:")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

happ_features = [
    "✅ Domain-based routing (DOMAIN, DOMAIN-SUFFIX, GEOSITE)",
    "✅ IP-based routing (IP-CIDR, GEOIP)",
    "✅ Per-app routing (Android: по package name)",
    "✅ Три действия: PROXY / DIRECT / BLOCK",
    "✅ Custom geosite.dat / geoip.dat URLs",
    "✅ Deeplink-установка профилей",
    "✅ Доставка через subscription headers/body",
]
for item in happ_features:
    p = doc.add_paragraph(item, style='List Bullet')
    for run in p.runs:
        run.font.size = Pt(10)
        run.font.name = 'Calibri'

# Client-Side vs Server-Side
doc.add_heading('4. Client-Side vs Server-Side Split Tunneling', level=2).style.font.name = 'Calibri'
client_vs_server = [
    ('Что решает', 'Какой трафик уходит в туннель', 'Куда сервер маршрутизирует'),
    ('Экономия трафика', '✅ Да (незаблокированное не на сервер)', '❌ Нет (всё через сервер)'),
    ('Скорость', '✅ Локальный трафик = полная скорость ISP', '❌ Весь трафик через сервер (latency)'),
    ('Нагрузка на сервер', '✅ Минимальная (только заблокированное)', '❌ Вся нагрузка'),
    ('Контроль провайдера', '⚠️ Зависит от клиента', '✅ Полный контроль'),
]
table_from_data(doc, ['Аспект', 'Client-Side (Happ)', 'Server-Side (Marzban)'], client_vs_server, cols=3)

p = doc.add_paragraph()
p.add_run("✅ РЕКОМЕНДАЦИЯ: ").font.bold = True
p.add_run("Client-side split tunneling (Happ routing) — правильный выбор. "
          "Экономит серверный трафик в 5-10x, не замедляет обычный интернет пользователя, "
          "Happ имеет встроенную поддержку, доставляется автоматически через subscription.")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

# Implementation complexity
doc.add_heading('5. Сложность реализации', level=2).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("СЛОЖНОСТЬ: НИЗКАЯ (3/10)").font.bold = True
for run in p.runs:
    run.font.size = Pt(11)
    run.font.name = 'Calibri'

impl_data = [
    ('Создать routing-профиль JSON', 'Gale', '2ч', 'На основе roscomvpn-routing, адаптировать'),
    ('Интегрировать в subscription API', 'Gale', '3ч', 'Header routing: {base64} в ответе'),
    ('Настроить CDN/proxy для geosite.dat', 'Olaf', '2ч', 'Проксировать GitHub release'),
    ('Создать deeplink для установки', 'Gale', '1ч', 'happ://routing/onadd/{base64}'),
    ('Тестирование на 3 платформах', 'Kim', '4ч', 'iOS, Android, Windows — проверка DNS leak'),
    ('Документация для пользователя', 'Lalo', '2ч', '"Как настроить" для мобильных'),
]
table_from_data(doc, ['Шаг', 'Кто', 'Часы', 'Описание'], impl_data, cols=4)

p = doc.add_paragraph()
p.add_run("ИТОГО: ~14 человеко-часов (2 дня работы)").font.bold = True
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

# UX
doc.add_heading('6. UX для пользователя (Zero-Config)', level=2).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("1. Пользователь устанавливает Happ\n")
p.add_run("2. Добавляет нашу subscription URL\n")
p.add_run("3. Subscription автоматически доставляет routing-профиль через HTTP-заголовок\n")
p.add_run("4. Happ скачивает geosite.dat с нашего CDN\n")
p.add_run("5. Split tunneling активен: заблокированное → VPN, остальное → напрямую\n\n")
p.add_run("НИКАКОЙ РУЧНОЙ НАСТРОЙКИ НЕ ТРЕБУЕТСЯ.")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

modes_data = [
    ('🎯 Умный (Whitelist)', 'Только заблокированное через VPN', '✅ По умолчанию'),
    ('🛡️ Полный (Full tunnel)', 'Весь трафик через VPN', 'Для параноиков'),
    ('⚡ Выключен', 'VPN off, всё напрямую', '—'),
]
table_from_data(doc, ['Режим', 'Описание', 'Default'], modes_data, cols=3)

# ===== SECTION: COSTS & GTM =====
doc.add_page_break()
costs_title = doc.add_heading('РАЗДЕЛ 10: Расходы на инфраструктуру и Go-To-Market стратегия', level=1)
costs_title.style.font.name = 'Calibri'

p = doc.add_paragraph()
p.add_run("Авторы: ").font.bold = True
p.add_run("Gale (Economics) + Lalo (Marketing)\nДата: 30 мая 2026")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

# Servers
doc.add_heading('1. Серверная инфраструктура (MVP — 4 сервера)', level=2).style.font.name = 'Calibri'
servers_data = [
    ('Netherlands (Amsterdam)', 'Hetzner CX21', '2vCPU / 4GB RAM / NVMe', '€5.7', '20TB'),
    ('Germany (Falkenstein)', 'Hetzner CX21', '2vCPU / 4GB RAM / NVMe', '€5.7', '20TB'),
    ('Finland (Helsinki)', 'Vultr', '2vCPU / 4GB RAM / SSD', '$4.0', '3TB'),
    ('UAE (Dubai)', 'Aeza.net', '1vCPU / 2GB RAM / 1Gbps', '€10.0', '25TB'),
]
table_from_data(doc, ['Локация', 'Провайдер', 'Конфиг', 'Цена/мес', 'Трафик'], servers_data, cols=5)

p = doc.add_paragraph()
p.add_run("ИТОГО MVP (3 основных): ").font.bold = True
p.add_run("€15.4 (~$17/мес)")
p.add_run("\nИТОГО с UAE: ")
p.add_run("€25.4 (~$27/мес)")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

# Bandwidth
doc.add_heading('2. Трафик и Bandwidth расходы', level=2).style.font.name = 'Calibri'
bandwidth_data = [
    ('MVP', '100', '2 TB', '$10', '$14', '$20'),
    ('Микро', '500', '10 TB', '$50', '$70', '$100'),
    ('Маленький', '1,000', '20 TB', '$100', '$140', '$200'),
    ('Средний', '5,000', '100 TB', '$500', '$700', '$1,000'),
    ('Крупный', '10,000', '200 TB', '$1,000', '$1,400', '$2,000'),
]
table_from_data(doc, ['Масштаб', 'Юзеров', 'Трафик/мес', '@ $5/TB', '@ $7/TB', '@ $10/TB'], bandwidth_data, cols=6)

# OPEX
doc.add_heading('3. OPEX таблица (4 сценария масштабирования)', level=2).style.font.name = 'Calibri'
opex_data = [
    ('VPS (3–5 серверов)', '$17', '$17', '$27', '$50'),
    ('Bandwidth @ $5/TB', '$10', '$50', '$100', '$500'),
    ('Happ (базовый)', '$0', '$0', '$0', '$0'),
    ('Marzban', '$0', '$0', '$0', '$0'),
    ('Домен + SSL', '$2', '$2', '$2', '$2'),
    ('Мониторинг', '$0', '$0', '$0', '$0'),
    ('Юр. обслуживание', '$25', '$25', '$25', '$25'),
    ('Affiliate (30% revenue)', '$0', '$210', '$840', '$5,250'),
    ('Разработка part-time', '$1,000', '$800', '$1,200', '$2,500'),
    ('ИТОГО OPEX', '$1,054', '$1,104', '$2,194', '$8,327'),
]
table_from_data(doc, ['Статья', 'MVP Мес.1', '500U Мес.3', '2KU Мес.6', '5KU Год'], opex_data, cols=5)

# Unit Economics
doc.add_heading('4. Unit Economics & Breakeven', level=2).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("Сценарий A: базовое ценообразование ($5/мес за Basic подписку)").font.bold = True
for run in p.runs:
    run.font.size = Pt(11)
    run.font.name = 'Calibri'

econ_data = [
    ('100 Users', '100 (100%)', '$500', '-$165', '$335', '$1,054', '-$719'),
    ('500 Users', '250 (50%)', '$2,500', '-$825', '$1,675', '$1,104', '+$571'),
    ('1,000 Users', '500 (50%)', '$5,000', '-$1,650', '$3,350', '$2,194', '+$1,156'),
    ('5,000 Users', '2,500 (50%)', '$25,000', '-$8,250', '$16,750', '$8,327', '+$8,423'),
]
table_from_data(doc, ['Масштаб', 'Платящих %', 'Revenue', 'Stars-33%', 'Net', 'OPEX', 'EBITDA'], econ_data, cols=7)

p = doc.add_paragraph()
p.add_run("Breakeven: ").font.bold = True
p.add_run("~500–700 платящих пользователей (~1000 активных)")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

# GTM Positioning
doc.add_heading('5. Позиционирование и Каналы привлечения', level=2).style.font.name = 'Calibri'

gtm_data = [
    ('Telegram-каналы (IT, обход)', '$5–15', '~1-2K/мес', '1 (MVP)'),
    ('YouTube-обзорщики VPN', '$10–30', '~500-1K кон.', '2'),
    ('4pda / Habr посты', '$0 (organic)', '~200-500', '3'),
    ('Affiliate (реф. программа)', '30% LTV', 'Органика', '1 (long-term)'),
    ('Telegram-бот каталог', '$0 (organic)', '~50-100', '4'),
]
table_from_data(doc, ['Канал', 'CPA / CAC', 'Объём потенциал', 'Приоритет'], gtm_data, cols=4)

# Pricing
doc.add_heading('6. Ценовая стратегия (Freemium + Tiers)', level=2).style.font.name = 'Calibri'
pricing_data = [
    ('Free (Freemium)', '$0', '1', 'Обычная', '1 GB', '5–8%'),
    ('Basic', '$4.99/мес', '1', 'Обычная', 'Unlimited', '60%'),
    ('Pro', '$7.99/мес', '3', 'Ускоренная', 'Unlimited', '30%'),
    ('Family', '$11.99/мес', '6', 'Приоритет', 'Unlimited', '5–10%'),
]
table_from_data(doc, ['Уровень', 'Цена', 'Девайсы', 'Скорость', 'Трафик', 'Конверсия'], pricing_data, cols=6)

# 90-Day Plan
doc.add_heading('7. План первых 90 дней', level=2).style.font.name = 'Calibri'

plan_90 = [
    ('Мес.1', 'Мягкий запуск в 3–5 TG-каналах', '100 юзеров', '~50 платящих', 'Цель breakeven близко'),
    ('Мес.2', 'Affiliate + YouTube спонсорства', '300–400 юзеров', '150–200 платящих', 'OPEX $1,104 снижается'),
    ('Мес.3', 'A/B тестирование цен + UAE-сервер', '500+ юзеров', '250+ платящих', 'BREAKEVEN достигнут! 🎉'),
]
table_from_data(doc, ['Период', 'Активность', 'Юзеров', 'Платящих', 'Результат'], plan_90, cols=5)

p = doc.add_paragraph()
p.add_run("KPI цели на 90 дней:").font.bold = True
for item in ["✅ 500+ юзеров всего",
             "✅ 250+ платящих",
             "✅ Conversion rate 50%+",
             "✅ Churn <20% мес.",
             "✅ CAC <$5",
             "✅ EBITDA >$0 (breakeven)",
             "✅ NPS 60+"]:
    p = doc.add_paragraph(item, style='List Bullet')
    for run in p.runs:
        run.font.size = Pt(10)
        run.font.name = 'Calibri'

# Final message
p = doc.add_paragraph()
p.add_run("\n\n✅ ИТОГОВОЕ РЕЗЮМЕ").font.bold = True
for run in p.runs:
    run.font.size = Pt(12)
    run.font.name = 'Calibri'

p = doc.add_paragraph()
p.add_run(
    "Split tunneling + Telegram Stars + Happ + 90-дневная Go-To-Market стратегия = "
    "реалистичный путь к профитабельности. "
    "Breakeven достижим при 500–700 платящих пользователях, что соответствует $1,500–2,000 месячной выручке. "
    "Маркетинг-спец расходы <$500 (в основном YouTube), остальное — organic + affiliate. "
    "Технология (Split Tunneling) интегрируется за 2 дня и даёт конкурентное преимущество."
)
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

# Save
output_path = '/home/alexey/banda/projects/r4g/docs/vpn-analysis-report.docx'
doc.save(output_path)

print(f"✅ Оба раздела добавлены в документ")
print(f"📄 Файл сохранён: {output_path}")

