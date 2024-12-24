"use strict";

var themeButton = document.getElementById('theme-button');
var themeMenu = document.getElementById('theme-menu');
var opened = false;

// template engine messes up quotes
function applyTheme(theme) {
	document.body.classList.remove('dark', 'highcontrast', 'light');
	document.body.classList.add(theme);
	localStorage.setItem('theme', theme);
	closeMenu();
}
function applyThemeLight()	{ applyTheme('light'); }
function applyThemeDark()	{ applyTheme('dark'); }
function applyThemeHighConstrast()	{ applyTheme('highcontrast'); }

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

function themeInit() {
	themeButton.classList.remove('hidden'); // js available
	
	var theme = localStorage.getItem('theme');
	
	if (theme) {
		applyTheme(theme);
		return;
	}
	
	if (!window.matchMedia)
		return;
	
	if (window.matchMedia('(prefers-color-scheme: light)').matches) {
		applyTheme('light');
		return;
	}
	
	applyTheme('dark');
}

themeInit();