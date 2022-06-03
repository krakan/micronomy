var icsElement = document.getElementById("ics");
if (icsElement.innerText != ""){ 
    let link = document.createElement('a');
    let yrinput = document.getElementById("yearinput");
    yrinput.append(link);
    let data = new Blob([icsElement.innerText],{ type: 'text/calendar' });
    link.setAttribute('download', 'Calendar.ics');
    //link.href = 'data:text/calendar;charset=utf-8,' + encodeURIComponent(icsElement.innerText);
    link.href = window.URL.createObjectURL(data);
    link.textContent = 'Download ICS';
    link.setAttribute('class','save-button');
}
