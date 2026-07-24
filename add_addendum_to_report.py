#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Add Addendum section to existing VPN analysis report
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
    """Create table from data"""
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

# Add page break before addendum
doc.add_page_break()

# === ADDENDUM SECTION ===
addendum_title = doc.add_heading('АДДЕНДУМ: Telegram Stars и платформа Happ', level=1)
addendum_title.style.font.name = 'Calibri'

p = doc.add_paragraph()
p.add_run("Автор: ").font.bold = True
p.add_run("Rob (Research & Analysis)")
p.add_run("\nДата: 30 мая 2026")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

# === 1. TELEGRAM STARS ===
doc.add_heading('1. Telegram Stars как платёжный инструмент', level=2).style.font.name = 'Calibri'

doc.add_heading('1.1 Что такое Telegram Stars', level=3).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("Telegram Stars — внутренняя цифровая валюта Telegram, введённая в мае 2024 года. "
          "Предназначена для покупки цифровых товаров и сервисов внутри ботов и Mini Apps. "
          "Это НЕ криптовалюта, а централизованная внутренняя единица расчёта.")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

doc.add_heading('1.2 Как работает для пользователя (покупка)', level=3).style.font.name = 'Calibri'
user_steps = [
    ('1', 'Пользователь открывает Telegram → настройки → Stars или бот @PremiumBot'),
    ('2', 'Покупает пакет Stars через Apple Pay / Google Pay / карту'),
    ('3', 'Stars зачисляются на баланс в приложении'),
    ('4', 'В нужном боте нажимает "Оплатить" → выбирает Stars → подтверждает'),
    ('5', 'Stars списываются, услуга активируется'),
]
table_from_data(doc, ['Шаг', 'Описание'], user_steps, cols=2)

p = doc.add_paragraph()
p.add_run("Пакеты для пользователей:").font.bold = True
for item in ["100 Stars ≈ $1.70–2.00 (с учётом 30% комиссии Apple/Google)",
             "Эффективная цена без store-комиссии: ~$0.013/Star",
             "Для РФ: @PremiumBot принимает рублёвые карты (СБП, МИР)"]:
    p = doc.add_paragraph(item, style='List Bullet')
    for run in p.runs:
        run.font.size = Pt(10)
        run.font.name = 'Calibri'

doc.add_heading('1.3 Как работает для разработчика (приём оплаты)', level=3).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("Техническая интеграция: ").font.bold = True
p.add_run("Вызов sendInvoice с currency: XTR, бот получает pre_checkout_query, затем successful_payment. "
          "Никакого специального разрешения не требуется — все боты могут принимать Stars немедленно.")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

doc.add_heading('1.4 Вывод средств (Fragment → TON → Фиат)', level=3).style.font.name = 'Calibri'
withdraw_data = [
    ('Apple/Google (на покупку)', '30% от суммы'),
    ('Fragment spread', '2–3% (норма), до 5–8% при волатильности'),
    ('Криптобиржа (TON → USDT)', '0.1–0.3%'),
    ('Итого эффективная комиссия', '~32–35% от суммы оплаты'),
]
table_from_data(doc, ['Уровень', 'Комиссия'], withdraw_data, cols=2)

p = doc.add_paragraph()
for item in ["Минимум вывода: 1 000 Stars (~$13 USD)",
             "Реальный цикл: 22–27 дней с момента оплаты до получения фиата",
             "21-дневный холд перед выводом"]:
    p = doc.add_paragraph(item, style='List Bullet')
    for run in p.runs:
        run.font.size = Pt(10)
        run.font.name = 'Calibri'

doc.add_heading('1.5 Сводная таблица: Stars для VPN в РФ', level=3).style.font.name = 'Calibri'
stars_summary = [
    ('Доступность для РФ', '✅ Высокая', '@PremiumBot принимает рублёвые карты'),
    ('Скорость активации', '✅ Мгновенная', 'Webhook в реальном времени'),
    ('Техническая сложность', '✅ Низкая', 'Bot API, currency: XTR'),
    ('Эффективная комиссия', '⚠️ 32–35%', 'Выше стандартных платёжек'),
    ('Скорость вывода', '⚠️ 22–27 дней', '21-дневный холд + крипто-конверсия'),
    ('Волатильность', '⚠️ Средняя', 'Зависит от курса TON'),
    ('Устойчивость к блокировкам', '⚠️ Ситуативная', '@PremiumBot устойчив, App Store уязвим'),
    ('Правовой риск (Россия)', '⚠️ Серый', 'Stars не попадают под прямое регулирование РКН'),
]
table_from_data(doc, ['Критерий', 'Оценка', 'Комментарий'], stars_summary, cols=3)

# === 2. HAPP ===
doc.add_heading('2. Платформа Happ — белая этикетка для VPN', level=2).style.font.name = 'Calibri'

doc.add_heading('2.1 Что такое Happ', level=3).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("Happ (happ.su / happ-proxy.com) — кроссплатформенный клиент для работы с прокси/VPN, "
          "построенный на Xray-core. Разработан российскими разработчиками. ")
p.add_run("Это НЕ конструктор VPN-бренда с нуля, а инфраструктурная платформа для провайдеров. "
          "Логотип/название остаются \"Happ\".")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

doc.add_heading('2.2 Технические характеристики', level=3).style.font.name = 'Calibri'
happ_tech = [
    ('Ядро', 'Xray-core'),
    ('Протоколы', 'VLESS (Reality), VMess, Trojan, Shadowsocks'),
    ('Платформы', 'iOS, Android, Windows, macOS, Linux, tvOS'),
    ('Серверы', 'НЕ предоставляет — провайдер управляет'),
    ('Управление устройствами', 'Limited Links, контроль HWID'),
    ('Кастомизация подписки', 'Название, текст анонса, ссылки поддержки'),
]
table_from_data(doc, ['Параметр', 'Значение'], happ_tech, cols=2)

doc.add_heading('2.3 Happ vs собственная разработка', level=3).style.font.name = 'Calibri'
happ_comparison = [
    ('Время до MVP (клиент)', 'Happ: 1–4 недели', 'Своя: 6–12 месяцев'),
    ('Стоимость разработки', 'Happ: минимальная', 'Своя: $100–300K'),
    ('iOS / Android / Desktop', 'Happ: ✅ готово', 'Своя: разрабатывать'),
    ('VLESS/Reality', 'Happ: ✅ есть', 'Своя: интеграция'),
    ('Брендинг', 'Happ: ⚠️ частичный', 'Своя: ✅ полный'),
    ('Контроль устройств', 'Happ: ✅ Limited Links', 'Своя: реализовывать'),
]
table_from_data(doc, ['Критерий', 'Happ', 'Собственная разработка'], happ_comparison, cols=3)

# === 3. ПЕРЕСМОТР ОЦЕНКИ ===
doc.add_heading('3. Пересмотр оценки', level=2).style.font.name = 'Calibri'

doc.add_heading('3.1 Telegram Stars: переоценка риска монетизации', level=3).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("Исходная оценка: ").font.bold = True
p.add_run("монетизация РФ — критический риск (отсутствие Visa/MC)\n")
p.add_run("Новые данные:").font.bold = True
for item in ["@PremiumBot принимает рублёвые карты → Stars покупаются без Visa/MC ✅",
             "Liberator VPN и Planet VPN уже работают на этой схеме ✅",
             "Интеграция Stars в бот: 1–3 дня (Bot API, currency: XTR) ✅",
             "Инцидент апреля 2026: @PremiumBot работал даже когда App Store упал ✅",
             "Комиссия 32–35% — выше стандарта, но терпима для VPN ($5–10/мес) ⚠️"]:
    p = doc.add_paragraph(item, style='List Bullet')
    for run in p.runs:
        run.font.size = Pt(10)
        run.font.name = 'Calibri'

p = doc.add_paragraph()
p.add_run("Пересмотренная оценка риска: ").font.bold = True
p.add_run("❌ Критический (было) → ⚠️ Высокий (стало)")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

doc.add_heading('3.2 Happ: переоценка технической готовности', level=3).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("Исходная оценка: ").font.bold = True
p.add_run("готовность команды — 62% (блокер: разработка клиентов 6–12 мес.)\n")
p.add_run("Новые данные:").font.bold = True
for item in ["Happ закрывает все клиентские платформы ✅",
             "VLESS/Reality поддержка — актуальный протокол для РФ ✅",
             "ZGC VPN и другие уже используют эту схему ✅",
             "Что НЕ нужно разрабатывать: нативные iOS/Android ($80–200K, 4–8 мес) ❌",
             "Что остаётся: Telegram-бот (2–4 недели), серверы (2–3 недели)"]:
    p = doc.add_paragraph(item, style='List Bullet')
    for run in p.runs:
        run.font.size = Pt(10)
        run.font.name = 'Calibri'

timeline_comparison = [
    ('Клиенты iOS/Android/Desktop', 'До Happ: 6–12 мес.', 'С Happ: 0 мес. (готово)'),
    ('Инфраструктура', 'До Happ: 1–2 мес.', 'С Happ: 1–2 мес.'),
    ('Telegram-бот + Stars', 'До Happ: 1–2 мес.', 'С Happ: 1–2 мес.'),
    ('Итого MVP', 'До Happ: 8–14 мес.', 'С Happ: 2–4 мес.'),
    ('CAPEX разработки', 'До Happ: $150–300K', 'С Happ: $20–50K'),
]
table_from_data(doc, ['Компонент', 'До Happ', 'С Happ'], timeline_comparison, cols=3)

p = doc.add_paragraph()
p.add_run("Пересмотренная оценка готовности: ").font.bold = True
p.add_run("62% (было) → ~85% (стало)")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

doc.add_heading('3.3 Новая итоговая оценка привлекательности', level=3).style.font.name = 'Calibri'
assessment_new = [
    ('Размер рынка', '9/10', '9/10', '→'),
    ('Темп роста', '8/10', '8/10', '→'),
    ('Конкурентная интенсивность', '3/10', '3/10', '→'),
    ('Барьер входа (нишевой)', '6/10', '8/10', '↑'),
    ('Монетизируемость (Россия)', '2/10', '5/10', '↑'),
    ('Технологическая устойчивость', '5/10', '5/10', '→'),
    ('ИТОГО', '5.5/10', '6.8/10', '↑ +1.3'),
]
table_from_data(doc, ['Критерий', 'Было', 'Стало', 'Изменение'], assessment_new, cols=4)

doc.add_heading('3.4 Новая рекомендация', level=3).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("Исходная рекомендация: ").font.bold = True
p.add_run("Conditional GO для нишевого РФ-продукта\n")
p.add_run("Новая рекомендация: ").font.bold = True
p.add_run("GO — с уточнёнными условиями\n")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

p = doc.add_paragraph()
p.add_run("✅ GO если:").font.bold = True
for item in ["Используется Happ как клиент (экономия $200K+ и 6+ мес.)",
             "Монетизация через Telegram Stars (@PremiumBot) + TON/крипто",
             "Серверы: VLESS/Reality (XRay-core) — проходит РКН сейчас",
             "MVP за 2–4 месяца, CAPEX $30–60K вместо $200–400K"]:
    p = doc.add_paragraph(item, style='List Bullet')
    for run in p.runs:
        run.font.size = Pt(10)
        run.font.name = 'Calibri'

p = doc.add_paragraph()
p.add_run("⚠️ Условия выживания:").font.bold = True
for item in ["Мониторинг блокировок протоколов (REALITY пока работает)",
             "Fallback-план: AmneziaWG или Trojan при блокировке",
             "Диверсификация платёжных методов: Stars + TON + другие",
             "Юридическая структура вне РФ (анонимность команды)",
             "НЕ зависеть от App Store — APK/F-Droid"]:
    p = doc.add_paragraph(item, style='List Bullet')
    for run in p.runs:
        run.font.size = Pt(10)
        run.font.name = 'Calibri'

doc.add_heading('3.5 Unit Economics с Happ + Stars', level=3).style.font.name = 'Calibri'
p = doc.add_paragraph()
p.add_run("Сценарий: 500 платящих × $7/мес (≈ 540 Stars)").font.italic = True
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

economics_text = """ДОХОДЫ:
500 users × $7/мес = $3,500/мес

COGS:
Серверы (5 локаций × $150) = $750
Bandwidth (45 TB × $5/TB) = $225
Stars-комиссия (32%) = $1,120
Итого COGS = $2,095 (60%)

ВАЛОВАЯ ПРИБЫЛЬ = $1,405 (40%)

OPEX:
1 разработчик part-time = $1,500
Telegram-бот hosting = $50
Happ Provider ID = $0–$100
Итого OpEx = $1,550–$1,650

EBITDA = -$245 – -$145/мес

Breakeven: ~600–700 платящих пользователей"""

p = doc.add_paragraph(economics_text)
for run in p.runs:
    run.font.size = Pt(9)
    run.font.name = 'Calibri'
    run.font.color.rgb = RGBColor(100, 100, 100)

p = doc.add_paragraph()
p.add_run("Это реалистичный сценарий для 1-2 человек команды с минимальным капиталом.")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'

# === SOURCES ===
doc.add_heading('Источники аддендума', level=2).style.font.name = 'Calibri'

sources = [
    "Telegram Official Blog — Telegram Stars введены (май 2024)",
    "Telegram API Docs — Stars API: core.telegram.org/api/stars",
    "GramBase — Telegram Stars Guide 2026",
    "liberator.one — VPN-сервис принимающий Stars",
    "Bloomberg — Russia's VPN Crackdown Caused Bank Outage (04.04.2026)",
    "Happ Official Site — happ.su, docs.happ-proxy.com",
    "ZGC VPN Wiki — Happ integration",
    "vpnon.io — Top VPN clients 2026",
]

for i, source in enumerate(sources, 1):
    p = doc.add_paragraph(source, style='List Number')
    for run in p.runs:
        run.font.size = Pt(10)
        run.font.name = 'Calibri'

# === FOOTER ===
p = doc.add_paragraph()
p.add_run("\nАддендум подготовлен: 30.05.2026 | Rob (Research & Analysis) | Banda Team")
for run in p.runs:
    run.font.size = Pt(10)
    run.font.name = 'Calibri'
    run.font.italic = True

# Save document (overwrite)
output_path = '/home/alexey/banda/projects/r4g/docs/vpn-analysis-report.docx'
doc.save(output_path)

print(f"✅ Аддендум добавлен в документ")
print(f"📄 Файл сохранён: {output_path}")

