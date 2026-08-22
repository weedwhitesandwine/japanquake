// The Japanese seismic intensity scale, and how to colour it.
//
// Shindo is not magnitude. Magnitude describes the earthquake; shindo
// describes what it did to a particular place, and it is the number people in
// Japan actually react to. It runs 1 to 7, with 5 and 6 each split into a weak
// and a strong band, so the ordering is not the ordering of the numerals.
.pragma library

var ORDER = ["1", "2", "3", "4", "5-", "5+", "6-", "6+", "7"]

function rank(s) {
  var i = ORDER.indexOf(s)
  return i < 0 ? 0 : i + 1
}

// JMA's own colours, kept rather than themed. Someone in Japan reads this ramp
// at a glance from years of seeing it on television, and a plugin that
// recoloured it to match a desktop would be throwing that away.
var COLORS = {
  "1":  "#5a6f7a",
  "2":  "#2b8ca6",
  "3":  "#2f9e57",
  "4":  "#e5b12e",
  "5-": "#f08a24",
  "5+": "#e2661d",
  "6-": "#d1433a",
  "6+": "#a8243a",
  "7":  "#7a2b8f"
}

function color(s) {
  return COLORS[s] || "#5a6f7a"
}

// Text a reader can act on, rather than a bare number.
var MEANING = {
  "1":  "barely perceptible",
  "2":  "felt by people lying down",
  "3":  "felt by most people indoors",
  "4":  "hanging objects swing hard",
  "5-": "furniture may topple",
  "5+": "hard to walk without holding on",
  "6-": "difficult to stay standing",
  "6+": "impossible to stay standing",
  "7":  "thrown by the shaking"
}

function meaning(s) {
  return MEANING[s] || ""
}
