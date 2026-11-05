#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const source = readFileSync(new URL('../entry/src/main/ets/theme/ThemeService.ets', import.meta.url), 'utf8');
const paletteClass = /export class ThemeSemanticPalette \{[\s\S]*?\n\}/.exec(source)?.[0];
const methodStart = /^  static semanticPalette\(rev: number\): ThemeSemanticPalette \{/m.exec(source);
assert.ok(paletteClass, 'semantic palette class');
assert.ok(methodStart, 'semantic palette resolver');
const methodEnd = source.indexOf('\n  }', methodStart.index);
assert.ok(methodEnd > methodStart.index, 'semantic palette resolver end');
const method = source.slice(methodStart.index, methodEnd + 4);

const context = vm.createContext({ AppBgTheme: {
  DEFAULT: 'default', MINT: 'mint', HOMEBREW: 'homebrew', NOCTIS: 'noctis'
} });
const Palette = vm.runInContext(stripTypeScriptTypes(
  `${paletteClass.replace('export class', 'class')}; ThemeSemanticPalette`, { mode: 'transform' }), context);
context.ThemeSemanticPalette = Palette;
const ThemeService = vm.runInContext(stripTypeScriptTypes(`
class ThemeService {
  static semanticPaletteKey = '';
  static semanticPaletteValue = null;
  static bgTheme = 'default';
  static dark = false;
  static isDark() { return this.dark; }
  ${method}
}
ThemeService`, { mode: 'transform' }), context);

function luminance(hex) {
  const channels = [1, 3, 5].map(index => parseInt(hex.slice(index, index + 2), 16) / 255);
  const linear = channels.map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function contrast(a, b) {
  const first = luminance(a), second = luminance(b);
  return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05);
}

const themes = [
  ['default', ['#F4F6FB', '#EBF1FD'], '#0A59F7'],
  ['mint', ['#F1FAF6', '#E2F3EC'], '#06715C'],
  ['homebrew', ['#FBF6ED', '#F3E8D6'], '#A84237'],
  ['noctis', ['#F3F4FC', '#E6E8F7'], '#5854B8']
];
const brands = new Set();
for (let index = 0; index < themes.length; index++) {
  const [theme, backgrounds, expectedBrand] = themes[index];
  ThemeService.bgTheme = theme;
  ThemeService.dark = false;
  const palette = ThemeService.semanticPalette(index + 1);
  assert.equal(palette.brandPrimary, expectedBrand, `${theme} brand color`);
  assert.equal(palette.backgroundVariant, theme !== 'default', `${theme} variant flag`);
  for (const role of ['textPrimary', 'textSecondary', 'textMuted', 'brandText', 'brandPrimary', 'brandHover']) {
    for (const background of backgrounds) {
      assert.ok(contrast(palette[role], background) >= 4.5,
        `${theme} ${role} contrast ${contrast(palette[role], background).toFixed(2)}:1`);
    }
  }
  brands.add(palette.brandPrimary);
}
assert.equal(brands.size, 4, 'each light background has a distinct brand color');

ThemeService.dark = true;
const dark = ThemeService.semanticPalette(10);
assert.equal(dark.backgroundVariant, false, 'dark mode ignores light background variants');
assert.equal(dark.brandPrimary, '#3B82F6');
assert.equal(dark.textPrimary, '#F8FAFC');

console.log('RESULT: four light palettes pass role mapping and WCAG AA text contrast; dark palette remains independent');
