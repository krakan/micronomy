var icsElement = document.getElementById("ics");
if (icsElement.innerText != ""){ 
    var a = document.createElement('a');
    var yrinput = document.getElementById("yearinput");
    yrinput.append(a);
    a.setAttribute('download','Calendar.ics');
    a.innerText = "Dowload ICS";
    a.setAttribute('href', 'data:text/plain;charset=utf-8,' + encodeURIComponent(icsElement.innerText));
    a.setAttribute('class', 'save-button');
}

