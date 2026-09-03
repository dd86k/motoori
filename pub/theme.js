"use strict";

var themeButton = document.getElementById('theme-button');
var themeMenu = document.getElementById('theme-menu');
var opened = false;

// applyTheme comes from the inline script in <head>: the theme class has to be
// on <html> before the first paint, which is long before this file runs.
function selectTheme(theme) {
	applyTheme(theme);
	closeMenu();
}
function applyThemeLight()	{ selectTheme('light'); }
function applyThemeDark()	{ selectTheme('dark'); }
function applyThemeHighConstrast()	{ selectTheme('highcontrast'); }

function openMenu() {
	opened = true;
	themeMenu.classList.remove('hidden');
}
function closeMenu() {
	opened = false;
	themeMenu.classList.add('hidden');
}

function toggleThemeMenu() {
	if (opened)
		closeMenu();
	else
		openMenu();
}

themeButton.classList.remove('hidden'); // js available
