#!/usr/bin/env python3
"""Check the editor's dynamic mood keys, which static reference scans skip.

This validates shipped copy, not Swift selection or persistence behavior.
Run: python3 -m unittest discover -s scripts/tests -p 'test_daily_metadata_localization.py'
"""

import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
COPY = {
    'daily.metadata.mood.happy': ('😊 Happy', '😊 开心'),
    'daily.metadata.mood.calm': ('😐 Calm', '😐 平静'),
    'daily.metadata.mood.low': ('😔 Low', '😔 低落'),
    'daily.metadata.mood.irritable': ('😤 Irritable', '😤 烦躁'),
    'daily.metadata.mood.excited': ('🤩 Excited', '🤩 兴奋'),
    'daily.metadata.mood.tired': ('😴 Tired', '😴 疲惫'),
    'daily.metadata.section.summary': ('SUMMARY', '摘要'),
    'daily.metadata.section.mood': ('MOOD', '心情'),
    'daily.metadata.section.weather': ('WEATHER', '天气'),
    'daily.metadata.section.cover': ('COVER IMAGE', '封面图片'),
}


def copy_errors(text, language):
    """Require exactly one well-formed declaration for every contracted key."""
    errors = []
    for key, values in COPY.items():
        prefix = re.compile(r'^\s*"' + re.escape(key) + r'"\s*=')
        declarations = [line for line in text.splitlines() if prefix.match(line)]
        if len(declarations) != 1:
            errors.append(f'{key}: expected one declaration, found {len(declarations)}')
            continue
        match = re.fullmatch(r'\s*"' + re.escape(key) + r'"\s*=\s*("(?:[^"\\]|\\.)*")\s*;\s*', declarations[0])
        if not match:
            errors.append(f'{key}: malformed declaration')
            continue
        try:
            value = json.loads(match.group(1))
        except ValueError:
            errors.append(f'{key}: malformed string')
            continue
        if value != values[language]:
            errors.append(f'{key}: unexpected localized copy')
    return errors


class DailyMetadataLocalizationTests(unittest.TestCase):
    def fixture(self, language):
        return '\n'.join(f'{json.dumps(key)} = {json.dumps(values[language], ensure_ascii=False)};' for key, values in COPY.items())

    def test_actual_english_and_chinese_resources(self):
        for language, directory in enumerate(('en.lproj', 'zh-Hans.lproj')):
            with self.subTest(locale=directory):
                text = (ROOT / 'DayPage/Resources' / directory / 'Localizable.strings').read_text()
                self.assertEqual(copy_errors(text, language), [])

    def test_valid_dual_language_fixture(self):
        for language in (0, 1):
            self.assertEqual(copy_errors(self.fixture(language), language), [])

    def test_missing_in_both_languages_is_rejected(self):
        for language in (0, 1):
            text = '\n'.join(self.fixture(language).splitlines()[1:])
            self.assertTrue(copy_errors(text, language))

    def test_missing_in_one_language_is_rejected(self):
        self.assertTrue(copy_errors('\n'.join(self.fixture(0).splitlines()[1:]), 0))
        self.assertEqual(copy_errors(self.fixture(1), 1), [])

    def test_duplicate_required_key_is_rejected(self):
        text = self.fixture(0)
        self.assertTrue(copy_errors(text + '\n' + text.splitlines()[0], 0))

    def test_chinese_copy_in_english_is_rejected(self):
        self.assertTrue(copy_errors(self.fixture(0).replace('😊 Happy', '😊 开心'), 0))

    def test_empty_raw_key_and_malformed_copy_are_rejected(self):
        for replacement in ('"";', '"daily.metadata.mood.happy";', '"😊 Happy"'):
            with self.subTest(replacement=replacement):
                self.assertTrue(copy_errors(self.fixture(0).replace('"😊 Happy";', replacement), 0))


if __name__ == '__main__':
    unittest.main()
