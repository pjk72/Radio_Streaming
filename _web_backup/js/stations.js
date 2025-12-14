const stations = [
    {
        id: 1,
        name: "Radio Deejay",
        genre: "Pop / Talk",
        url: "http://radiodeejay-lh.akamaihd.net/i/RadioDeejay_Live_1@189857/master.m3u8",
        icon: "fa-record-vinyl",
        logo: "https://upload.wikimedia.org/wikipedia/commons/thumb/5/52/Logo_Deejay.svg/512px-Logo_Deejay.svg.png",
        color: "#D32F2F",
        category: "Italian"
    },
    {
        id: 2,
        name: "Radio 105",
        genre: "Pop / Hits",
        url: "http://icecast.unitedradio.it/Radio105.mp3",
        icon: "fa-bolt",
        logo: "https://upload.wikimedia.org/wikipedia/commons/thumb/e/ed/Radio_105_logo.svg/512px-Radio_105_logo.svg.png",
        color: "#FBC02D",
        category: "Italian"
    },
    {
        id: 3,
        name: "RAI Radio 1",
        genre: "News / Talk",
        url: "http://icestreaming.rai.it/1.mp3",
        icon: "fa-tower-broadcast",
        logo: "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1a/Rai_Radio_1_-_Logo_2017.svg/512px-Rai_Radio_1_-_Logo_2017.svg.png",
        color: "#1976D2",
        category: "Italian"
    },
    {
        id: 4,
        name: "RTL 102.5",
        genre: "Hit Music",
        url: "https://shoutcast.rtl.it/rt1025.mp3",
        icon: "fa-star",
        logo: "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4b/RTL_102.5_%28logo%29.png/512px-RTL_102.5_%28logo%29.png",
        color: "#000000",
        category: "Italian"
    },
    {
        id: 5,
        name: "RDS",
        genre: "Hits",
        url: "https://icestreaming.rds.it/rds",
        icon: "fa-radio",
        logo: "https://upload.wikimedia.org/wikipedia/commons/thumb/e/ed/RDS_logo.svg/512px-RDS_logo.svg.png",
        color: "#C2185B",
        category: "Italian"
    },
    {
        id: 6,
        name: "Jazz Cafe",
        genre: "Jazz",
        url: "http://jazz.streamr.ru/jazz-64.mp3",
        icon: "fa-saxophone",
        logo: "https://ui-avatars.com/api/?name=Jazz+Cafe&background=d63031&color=fff&size=128&font-size=0.5",
        color: "#d63031",
        category: "International"
    }
];

// Export for use in other files if using modules, but here we just load it globally
window.stations = stations;
