function flash(target) {
  var bgcolor = target.style.background;
  target.style.background = 'green';
  var t = setTimeout(function(){unflash(target, bgcolor)}, 100);
}
function unflash(target, bgcolor) {
  target.style.background = bgcolor;
}

var lastTarget;
function persistTarget(form) {
  var input = document.createElement('input');
  input.type = 'hidden';
  input.name = 'last-target'
  input.value = lastTarget.name;
  form.appendChild(input);
}

document.addEventListener("keydown", documentKeyDown);
function documentKeyDown(evt) {
  if (evt.which >= 37 && evt.which <= 41) {
    if(evt.ctrlKey) {
      switch (evt.which) {
      case 37:
        var prevBtn = document.getElementById('prevWk');
        persistTarget(prevBtn.form);
        prevBtn.click();
        break;
      case 39:
        var nextBtn = document.getElementById('nextWk');
        persistTarget(nextBtn.form);
        nextBtn.click();
        break;
      case 38:
      case 40:
        if (lastTarget == null) {
          lastTarget = document.activeElement
        } else if (lastTarget != null && lastTarget != document.activeElement) {
          lastTarget.focus();
          flash(lastTarget);
          evt.preventDefault()
        }
        break;
      }
    }
  }
}

function setupNavigation() {
  var boxes = document.getElementsByClassName('nav-field');
  var rows = document.getElementsByClassName('nav-row').length;
  var cols = boxes.length / rows;
  lastTarget = document.getElementById('focus-target');
  if (lastTarget == null) {
    lastTarget = boxes[0];
  }

  if (cols) {
    lastTarget.focus();
    lastTarget.selectionStart = 0;
    lastTarget.selectionEnd = lastTarget.value.length;
  }

  for (var i = 0; i < boxes.length; i++) {
    boxes[i].addEventListener('keydown', hoursKeyDown.bind(i));
  }

  function hoursKeyDown(evt) {
    var idx = this
    if (evt.ctrlKey) {
      return;
    }

    if (evt.which == 27) { // escape key
      lastTarget = evt.target;
      evt.target.blur();

    } else if (evt.which >= 37 && evt.which <= 41) { // arrow keys
      var row = Math.floor(idx / cols);
      var col = idx - row * cols;

      switch (evt.which) {
      case 38: // Up
        idx = (idx - cols + boxes.length) % boxes.length;
        break;
      case 40: // Down
        idx = (idx + cols) % boxes.length;
        break;
      case 37: // Left
        if (evt.target.selectionEnd > 0) {
          return;
        }
        idx = row * cols + (col - 1 + cols) % cols;
        break;
      case 39: // Right
        if (evt.target.selectionStart < evt.target.value.length) {
          return;
        }
        idx = row * cols + (col + 1) % cols;
        break;
      }
      //idx = Math.floor(idx);
      var target = boxes[idx];

      if (target != null) {
        target.focus();
        target = document.activeElement;
        lastTarget = target;
        switch (evt.which) {
        case 37:  // Left
          target.selectionStart = 0;
          target.selectionEnd = 0;
          break;
        case 39: // Right
          target.selectionStart = target.value.length;
          target.selectionEnd = target.value.length;
          break;
        default: // Up or Dowm
          target.selectionStart = 0;
          target.selectionEnd = target.value.length;
          break;
        }
        evt.preventDefault();
      }
    } else if (evt.which == 13) { // enter
      persistTarget(document.getElementById('hourForm'));
    }
  }
}
