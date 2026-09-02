"use strict";

// Rows are matched against a cached lowercase copy of their text: re-reading
// textContent on every keystroke is what makes the multi-thousand row tables lag.
function tableFilterInit(input) {
	var table = document.getElementById(input.dataset.table);
	if (!table || !table.tBodies.length)
		return;

	var rows = table.tBodies[0].rows;
	var haystacks = new Array(rows.length);
	for (var i = 0; i < rows.length; ++i)
		haystacks[i] = rows[i].textContent.toLowerCase();

	var footer = table.tFoot ? table.tFoot.rows[0].cells[0] : null;
	var total = footer ? footer.textContent : null;

	input.addEventListener('input', function () {
		var needle = input.value.toLowerCase();
		var shown = 0;
		for (var i = 0; i < rows.length; ++i) {
			var match = haystacks[i].indexOf(needle) >= 0;
			rows[i].classList.toggle('hidden', !match);
			if (match)
				++shown;
		}
		if (footer)
			footer.textContent = needle ? 'Showing ' + shown + ' of ' + total : total;
	});

	input.classList.remove('hidden'); // js available
}

var tableFilters = document.getElementsByClassName('table-filter');
for (var i = 0; i < tableFilters.length; ++i)
	tableFilterInit(tableFilters[i]);
