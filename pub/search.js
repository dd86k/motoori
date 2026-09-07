"use strict";

// "/" focuses the search box, unless the key is meant for a field being typed in.
// The home page's own box wins over the nav one when both are on the page.
var navInput = document.getElementById('search-input');
var searchInput = document.getElementById('hero-search-input') || navInput;

function searchTypingInto(element) {
	if (!element)
		return false;
	if (element.isContentEditable)
		return true;
	var tag = element.tagName;
	return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
}

if (navInput)
	navInput.placeholder = 'Search (/)'; // only true with js available

if (searchInput) {
	document.addEventListener('keydown', function (event) {
		if (event.key !== '/' || event.ctrlKey || event.altKey || event.metaKey)
			return;
		if (searchTypingInto(event.target))
			return;
		event.preventDefault();
		searchInput.focus();
		searchInput.select();
	});
}
