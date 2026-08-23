#!/usr/bin/env python3
"""
Deterministic Bazi (Four Pillars) calculator.

Usage:
    python compute_bazi.py --year 1994 --month 10 --day 5 --hour 23 --minute 30

Output: JSON with all pillar info + Ten Gods + current Liuyue analysis.

LLMs are bad at Bazi arithmetic (node-boundary slip, zi-hour day-roll, 60-cycle
off-by-one). This script delegates to lunar_python which handles all of it.
Never try to compute pillars from scratch in an LLM.
"""

import argparse
import json
import sys
from datetime import datetime

try:
    from lunar_python import Solar
except ImportError:
    print(json.dumps({
        "error": "lunar_python not installed. Run: pip install lunar_python"
    }))
    sys.exit(1)


# Five elements per stem and branch (standard mapping)
STEM_ELEMENT = {
    '甲': '木', '乙': '木',
    '丙': '火', '丁': '火',
    '戊': '土', '己': '土',
    '庚': '金', '辛': '金',
    '壬': '水', '癸': '水',
}

BRANCH_ELEMENT = {
    '子': '水', '丑': '土', '寅': '木', '卯': '木',
    '辰': '土', '巳': '火', '午': '火', '未': '土',
    '申': '金', '酉': '金', '戌': '土', '亥': '水',
}

# Ten Gods relative to day master. (day_master_element, other_element, yin_yang_match) → god
# Stem polarity: 甲丙戊庚壬 = yang; 乙丁己辛癸 = yin
STEM_POLARITY = {
    '甲': 'yang', '丙': 'yang', '戊': 'yang', '庚': 'yang', '壬': 'yang',
    '乙': 'yin',  '丁': 'yin',  '己': 'yin',  '辛': 'yin',  '癸': 'yin',
}


def compute_liuyue(year, month, day):
    """
    Given a Gregorian date, return the 流月 (monthly pillar) that date falls within.
    Uses the same lunar_python engine for consistency.
    """
    solar = Solar.fromYmdHms(year, month, day, 12, 0, 0)
    ec = solar.getLunar().getEightChar()
    return ec.getMonth()


def compute_chart(year, month, day, hour, minute, sect=1):
    """
    Compute four pillars + ten gods + metadata for a given datetime.

    Args:
        sect: lunar_python sect convention for zi-hour day rollover.
              sect=1: day pillar ROLLS at 23:00 (classical Bazi practice,
                      the 23:00-00:00 window uses the NEXT day's day pillar).
              sect=2: day pillar rolls at 00:00 (modern astronomical convention,
                      the 23:00-00:00 window keeps the CURRENT day's pillar).
              Default is 1 (most classical Bazi practitioners and traditional
              排盘 software use this).

    Returns a dict ready for JSON output.
    """
    solar = Solar.fromYmdHms(year, month, day, hour, minute, 0)
    lunar = solar.getLunar()
    ec = lunar.getEightChar()
    ec.setSect(sect)

    day_master_stem = ec.getDayGan()
    day_master_element = STEM_ELEMENT[day_master_stem]
    day_master_polarity = STEM_POLARITY[day_master_stem]

    chart = {
        "input": {
            "solar_date": f"{year}-{month:02d}-{day:02d}",
            "solar_time": f"{hour:02d}:{minute:02d}",
            "lunar_date": str(lunar),
        },
        "pillars": {
            "year": {
                "stem": ec.getYearGan(),
                "branch": ec.getYearZhi(),
                "full": ec.getYear(),
                "stem_element": STEM_ELEMENT[ec.getYearGan()],
                "branch_element": BRANCH_ELEMENT[ec.getYearZhi()],
                "hidden_stems": ec.getYearHideGan(),
                "ten_god_stem": ec.getYearShiShenGan(),
                "ten_gods_branch": ec.getYearShiShenZhi(),
                "nayin": ec.getYearNaYin(),
            },
            "month": {
                "stem": ec.getMonthGan(),
                "branch": ec.getMonthZhi(),
                "full": ec.getMonth(),
                "stem_element": STEM_ELEMENT[ec.getMonthGan()],
                "branch_element": BRANCH_ELEMENT[ec.getMonthZhi()],
                "hidden_stems": ec.getMonthHideGan(),
                "ten_god_stem": ec.getMonthShiShenGan(),
                "ten_gods_branch": ec.getMonthShiShenZhi(),
                "nayin": ec.getMonthNaYin(),
            },
            "day": {
                "stem": ec.getDayGan(),
                "branch": ec.getDayZhi(),
                "full": ec.getDay(),
                "stem_element": STEM_ELEMENT[ec.getDayGan()],
                "branch_element": BRANCH_ELEMENT[ec.getDayZhi()],
                "hidden_stems": ec.getDayHideGan(),
                "ten_god_stem": "日主",
                "ten_gods_branch": ec.getDayShiShenZhi(),
                "nayin": ec.getDayNaYin(),
            },
            "hour": {
                "stem": ec.getTimeGan(),
                "branch": ec.getTimeZhi(),
                "full": ec.getTime(),
                "stem_element": STEM_ELEMENT[ec.getTimeGan()],
                "branch_element": BRANCH_ELEMENT[ec.getTimeZhi()],
                "hidden_stems": ec.getTimeHideGan(),
                "ten_god_stem": ec.getTimeShiShenGan(),
                "ten_gods_branch": ec.getTimeShiShenZhi(),
                "nayin": ec.getTimeNaYin(),
            },
        },
        "day_master": {
            "stem": day_master_stem,
            "element": day_master_element,
            "polarity": day_master_polarity,
        },
        "element_count": count_elements(ec),
    }

    # Also compute the Ten God of each pillar stem/branch vs day master
    # so LLM has everything it needs without recomputing
    return chart


def count_elements(ec):
    """Count total occurrences of each element across all 8 characters (stems + branches)."""
    counts = {'木': 0, '火': 0, '土': 0, '金': 0, '水': 0}
    stems = [ec.getYearGan(), ec.getMonthGan(), ec.getDayGan(), ec.getTimeGan()]
    branches = [ec.getYearZhi(), ec.getMonthZhi(), ec.getDayZhi(), ec.getTimeZhi()]
    for s in stems:
        counts[STEM_ELEMENT[s]] += 1
    for b in branches:
        counts[BRANCH_ELEMENT[b]] += 1
    return counts


def compute_ten_god(day_master_stem, other_stem):
    """
    Compute the Ten God (十神) of `other_stem` relative to `day_master_stem`.
    Ten Gods depend on element relationship + polarity match.
    """
    dm_elem = STEM_ELEMENT[day_master_stem]
    dm_pol = STEM_POLARITY[day_master_stem]
    other_elem = STEM_ELEMENT[other_stem]
    other_pol = STEM_POLARITY[other_stem]
    same_polarity = (dm_pol == other_pol)

    # Generation cycle: 木生火, 火生土, 土生金, 金生水, 水生木
    # Control cycle: 木克土, 土克水, 水克火, 火克金, 金克木
    generates = {'木': '火', '火': '土', '土': '金', '金': '水', '水': '木'}
    controls  = {'木': '土', '土': '水', '水': '火', '火': '金', '金': '木'}

    if dm_elem == other_elem:
        return '比肩' if same_polarity else '劫财'
    elif generates[dm_elem] == other_elem:
        return '食神' if same_polarity else '伤官'
    elif controls[dm_elem] == other_elem:
        return '偏财' if same_polarity else '正财'
    elif controls[other_elem] == dm_elem:
        return '七杀' if same_polarity else '正官'
    elif generates[other_elem] == dm_elem:
        return '偏印' if same_polarity else '正印'
    return '?'


def analyze_liuyue_interaction(chart, liuyue_pillar):
    """
    Analyze how the current monthly pillar interacts with the personal chart.
    Returns structured info for the LLM to use in interpretation.
    """
    liuyue_stem = liuyue_pillar[0]
    liuyue_branch = liuyue_pillar[1]
    day_master = chart["day_master"]["stem"]

    # Ten God of the liuyue stem relative to day master
    liuyue_ten_god = compute_ten_god(day_master, liuyue_stem)

    # Branch interactions
    CLASH_PAIRS = {'子': '午', '午': '子', '丑': '未', '未': '丑',
                   '寅': '申', '申': '寅', '卯': '酉', '酉': '卯',
                   '辰': '戌', '戌': '辰', '巳': '亥', '亥': '巳'}
    SIX_COMBINE = {'子': '丑', '丑': '子', '寅': '亥', '亥': '寅',
                   '卯': '戌', '戌': '卯', '辰': '酉', '酉': '辰',
                   '巳': '申', '申': '巳', '午': '未', '未': '午'}

    # 三合局 (three-way combine) and 半合 (two-way partial combine) — element produced
    # 申子辰 → 水;亥卯未 → 木;寅午戌 → 火;巳酉丑 → 金
    SAN_HE_GROUPS = {
        '水': ['申', '子', '辰'],
        '木': ['亥', '卯', '未'],
        '火': ['寅', '午', '戌'],
        '金': ['巳', '酉', '丑'],
    }

    interactions = []
    for position in ['year', 'month', 'day', 'hour']:
        personal_branch = chart["pillars"][position]["branch"]

        # Clash (冲)
        if CLASH_PAIRS.get(liuyue_branch) == personal_branch:
            interactions.append({
                "type": "冲",
                "liuyue_branch": liuyue_branch,
                "personal_branch": personal_branch,
                "personal_position": position,
                "meaning": f"流月{liuyue_branch} 冲 {position}柱 {personal_branch}"
            })

        # Six Combine (六合)
        if SIX_COMBINE.get(liuyue_branch) == personal_branch:
            interactions.append({
                "type": "六合",
                "liuyue_branch": liuyue_branch,
                "personal_branch": personal_branch,
                "personal_position": position,
                "meaning": f"流月{liuyue_branch} 六合 {position}柱 {personal_branch}"
            })

        # Semi-combine (半合局) — two of three san-he branches present
        for element, group in SAN_HE_GROUPS.items():
            if liuyue_branch in group and personal_branch in group and liuyue_branch != personal_branch:
                interactions.append({
                    "type": "半合",
                    "liuyue_branch": liuyue_branch,
                    "personal_branch": personal_branch,
                    "personal_position": position,
                    "combine_element": element,
                    "meaning": f"流月{liuyue_branch} 与 {position}柱 {personal_branch} 半合{element}局"
                })

    # Full 三合局 check — if liuyue branch + two personal branches form complete three-way
    personal_branches = [chart["pillars"][p]["branch"] for p in ['year', 'month', 'day', 'hour']]
    for element, group in SAN_HE_GROUPS.items():
        if liuyue_branch in group:
            other_two = [b for b in group if b != liuyue_branch]
            if all(b in personal_branches for b in other_two):
                interactions.append({
                    "type": "三合",
                    "liuyue_branch": liuyue_branch,
                    "personal_branches": other_two,
                    "combine_element": element,
                    "meaning": f"流月{liuyue_branch} + 本命{' '.join(other_two)} → 三合{element}局完整成局"
                })

    return {
        "liuyue": liuyue_pillar,
        "liuyue_stem": liuyue_stem,
        "liuyue_branch": liuyue_branch,
        "liuyue_ten_god_stem": liuyue_ten_god,
        "branch_interactions": interactions,
    }


def main():
    parser = argparse.ArgumentParser(description="Compute Bazi (Four Pillars) deterministically.")
    parser.add_argument("--year", type=int, required=True, help="Birth year (Gregorian)")
    parser.add_argument("--month", type=int, required=True, help="Birth month (1-12)")
    parser.add_argument("--day", type=int, required=True, help="Birth day (1-31)")
    parser.add_argument("--hour", type=int, required=True,
                        help="Birth hour (0-23, local Chinese solar time). Use 12 if unknown.")
    parser.add_argument("--minute", type=int, default=0, help="Birth minute (0-59)")
    parser.add_argument("--hour-unknown", action="store_true",
                        help="Flag that hour is not known. Uses noon but marks hour pillar unreliable.")
    parser.add_argument("--sect", type=int, default=1, choices=[1, 2],
                        help="Zi-hour convention: 1 = day rolls at 23:00 (classical Bazi, DEFAULT), "
                             "2 = day rolls at 00:00 (modern astronomical)")
    parser.add_argument("--analyze-date", type=str, default=None,
                        help="Gregorian YYYY-MM-DD date to analyze 流月 interaction. Defaults to today.")
    args = parser.parse_args()

    # Compute core chart
    chart = compute_chart(args.year, args.month, args.day, args.hour, args.minute, sect=args.sect)
    chart["sect_convention"] = f"Sect {args.sect} ({'day rolls at 23:00 — classical' if args.sect == 1 else 'day rolls at 00:00 — modern'})"

    # Flag unreliable hour
    if args.hour_unknown:
        chart["hour_unknown"] = True
        chart["pillars"]["hour"]["note"] = "UNRELIABLE — birth hour not provided"

    # Compute current liuyue analysis
    if args.analyze_date:
        analyze_year, analyze_month, analyze_day = [int(x) for x in args.analyze_date.split("-")]
    else:
        today = datetime.today()
        analyze_year, analyze_month, analyze_day = today.year, today.month, today.day

    liuyue = compute_liuyue(analyze_year, analyze_month, analyze_day)
    chart["liuyue_analysis"] = analyze_liuyue_interaction(chart, liuyue)
    chart["liuyue_analysis"]["analyze_date"] = f"{analyze_year}-{analyze_month:02d}-{analyze_day:02d}"

    # Also compute the day pillar of the analyze_date (for "today's reaction" reading)
    analyze_solar = Solar.fromYmdHms(analyze_year, analyze_month, analyze_day, 12, 0, 0)
    analyze_ec = analyze_solar.getLunar().getEightChar()
    chart["liuyue_analysis"]["today_day_pillar"] = analyze_ec.getDay()
    chart["liuyue_analysis"]["today_day_stem_ten_god"] = compute_ten_god(
        chart["day_master"]["stem"], analyze_ec.getDayGan()
    )

    print(json.dumps(chart, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
