"use strict";

var themeButton = document.getElementById('theme-button');
var themeMenu = document.getElementById('theme-menu');
var opened = false;

// applyTheme comes from the inline script in <head>: the theme class has to be
// on <html> before the first paint, which is long before this file runs.
function selectTheme(theme) {
	applyTheme(theme);
	closeMenu();
	themeButton.focus(); // the button that had focus is inside the menu we just hid
}
function applyThemeLight()	{ selectTheme('light'); }
function applyThemeDark()	{ selectTheme('dark'); }
function applyThemeHighConstrast()	{ selectTheme('highcontrast'); }

function openMenu() {
	opened = true;
	themeMenu.classList.remove('hidden');
	themeButton.setAttribute('aria-expanded', 'true');
}
function closeMenu() {
	opened = false;
	themeMenu.classList.add('hidden');
	themeButton.setAttribute('aria-expanded', 'false');
}

function toggleThemeMenu() {
	if (opened)
		closeMenu();
	else
		openMenu();
}

// A menu that can only be dismissed by hitting its own button is a trap for
// anyone who opened it by accident.
document.addEventListener('keydown', function (event) {
	if (event.key !== 'Escape' || opened === false)
		return;
	closeMenu();
	themeButton.focus();
});
document.addEventListener('click', function (event) {
	if (opened === false)
		return;
	// The button's own onclick already toggled; closing here would undo it.
	if (themeButton.contains(event.target) || themeMenu.contains(event.target))
		return;
	closeMenu();
});

themeButton.classList.remove('hidden'); // js available
