"use strict";

// "/" focuses the nav search box, unless the key is meant for a field being typed in.
var searchInput = document.getElementById('search-input');

function searchTypingInto(element) {
	if (!element)
		return false;
	if (element.isContentEditable)
		return true;
	var tag = element.tagName;
	return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
}

if (searchInput) {
	searchInput.placeholder = 'Search (/)'; // only true with js available

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
