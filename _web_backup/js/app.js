class RadioApp {
    constructor() {
        this.stations = window.stations;
        this.currentStationIndex = 0;
        this.isPlaying = false;
        this.audio = new Audio();
        this.audio.crossOrigin = "anonymous"; // Needed for Web Audio API visualizer
        this.visualizer = new AudioVisualizer('visualizer');
        this.visualizerInitialized = false;

        this.elements = {
            grid: document.getElementById('stations-grid'),
            playBtn: document.getElementById('play-btn'),
            prevBtn: document.getElementById('prev-btn'),
            nextBtn: document.getElementById('next-btn'),
            volumeSlider: document.getElementById('volume-slider'),
            currentStation: document.getElementById('current-station'),
            currentGenre: document.getElementById('current-genre'),
            currentArt: document.getElementById('current-art'),
            search: document.querySelector('.search-bar input')
        };

        this.init();
    }

    init() {
        this.renderStations(this.stations);
        this.setupEventListeners();
        this.updatePlayerUI();
    }

    isFavorite(id) {
        const favs = JSON.parse(localStorage.getItem('favorites') || '[]');
        return favs.includes(id);
    }

    toggleFavorite(id, btnElement) {
        let favs = JSON.parse(localStorage.getItem('favorites') || '[]');
        if (favs.includes(id)) {
            favs = favs.filter(fId => fId !== id);
            btnElement.classList.remove('active');
            btnElement.querySelector('i').className = 'fa-regular fa-heart';
        } else {
            favs.push(id);
            btnElement.classList.add('active');
            btnElement.querySelector('i').className = 'fa-solid fa-heart';
        }
        localStorage.setItem('favorites', JSON.stringify(favs));
    }

    renderStations(stationsToRender) {
        this.elements.grid.innerHTML = '';

        // Group stations by category
        const groups = {};
        stationsToRender.forEach(station => {
            const cat = station.category || 'Other';
            if (!groups[cat]) groups[cat] = [];
            groups[cat].push(station);
        });

        const sortedCategories = Object.keys(groups).sort((a, b) => {
            if (a === 'Italian') return -1;
            if (b === 'Italian') return 1;
            return a.localeCompare(b);
        });

        sortedCategories.forEach(category => {
            const section = document.createElement('div');
            section.className = 'category-section';

            const header = document.createElement('h2');
            header.className = 'category-header';
            header.textContent = category;
            section.appendChild(header);

            const grid = document.createElement('div');
            grid.className = 'stations-category-grid';

            groups[category].forEach(station => {
                const card = document.createElement('div');
                card.className = 'station-card glass-panel';
                card.onclick = (e) => {
                    if (e.target.closest('.favorite-btn')) return;
                    this.playStation(station.id);
                };

                const isFav = this.isFavorite(station.id);

                let visualHtml = '';
                if (station.logo) {
                    visualHtml = `<img src="${station.logo}" alt="${station.name}" class="station-logo">`;
                } else {
                    visualHtml = `
                        <div class="station-icon" style="color: ${station.color}">
                            <i class="fa-solid ${station.icon}"></i>
                        </div>
                    `;
                }

                card.innerHTML = `
                    <button class="favorite-btn ${isFav ? 'active' : ''}" onclick="window.app.toggleFavorite(${station.id}, this)">
                        <i class="${isFav ? 'fa-solid' : 'fa-regular'} fa-heart"></i>
                    </button>
                    ${visualHtml}
                    <div class="station-info">
                        <h4>${station.name}</h4>
                        <p>${station.genre}</p>
                    </div>
                `;
                grid.appendChild(card);
            });

            section.appendChild(grid);
            this.elements.grid.appendChild(section);
        });
    }

    setupEventListeners() {
        this.elements.playBtn.addEventListener('click', () => this.togglePlay());
        this.elements.prevBtn.addEventListener('click', () => this.playPrev());
        this.elements.nextBtn.addEventListener('click', () => this.playNext());

        this.elements.volumeSlider.addEventListener('input', (e) => {
            this.audio.volume = e.target.value;
        });

        this.elements.search.addEventListener('input', (e) => {
            const query = e.target.value.toLowerCase();
            const filtered = this.stations.filter(s =>
                s.name.toLowerCase().includes(query) ||
                s.genre.toLowerCase().includes(query)
            );
            this.renderStations(filtered);
        });

        // Error handling
        this.audio.addEventListener('error', (e) => {
            console.error("Audio Error:", e);
            // alert("Error playing stream. It might be offline.");
            this.isPlaying = false;
            this.updatePlayButton();
        });
    }

    initializeVisualizer() {
        if (!this.visualizerInitialized) {
            try {
                this.visualizer.setup(this.audio);
                this.visualizer.start();
                this.visualizerInitialized = true;
            } catch (e) {
                console.warn("Visualizer init failed (likely CORS or user interaction needed):", e);
            }
        }
    }

    playStation(id) {
        const index = this.stations.findIndex(s => s.id === id);
        if (index !== -1) {
            this.currentStationIndex = index;
            this.loadStation(this.stations[index]);
            this.play();
        }
    }

    loadStation(station) {
        this.audio.src = station.url;
        this.elements.currentStation.textContent = station.name;
        this.elements.currentGenre.textContent = station.genre;
        this.elements.currentArt.style.backgroundColor = station.color;

        if (station.logo) {
            this.elements.currentArt.innerHTML = `<img src="${station.logo}" style="width:100%; height:100%; object-fit:contain; border-radius: 8px;">`;
        } else {
            this.elements.currentArt.innerHTML = `<i class="fa-solid ${station.icon}" style="color: white; font-size: 1.5rem; display: flex; justify-content: center; align-items: center; height: 100%;"></i>`;
        }
    }

    play() {
        this.initializeVisualizer();
        this.audio.play().then(() => {
            this.isPlaying = true;
            this.updatePlayButton();
        }).catch(err => {
            console.error("Play failed:", err);
            this.isPlaying = false;
            this.updatePlayButton();
        });
    }

    pause() {
        this.audio.pause();
        this.isPlaying = false;
        this.updatePlayButton();
    }

    togglePlay() {
        if (this.isPlaying) {
            this.pause();
        } else {
            if (!this.audio.src) {
                this.playStation(this.stations[0].id);
            } else {
                this.play();
            }
        }
    }

    playNext() {
        this.currentStationIndex = (this.currentStationIndex + 1) % this.stations.length;
        this.playStation(this.stations[this.currentStationIndex].id);
    }

    playPrev() {
        this.currentStationIndex = (this.currentStationIndex - 1 + this.stations.length) % this.stations.length;
        this.playStation(this.stations[this.currentStationIndex].id);
    }

    updatePlayButton() {
        const icon = this.elements.playBtn.querySelector('i');
        if (this.isPlaying) {
            icon.className = 'fa-solid fa-pause';
        } else {
            icon.className = 'fa-solid fa-play';
        }
    }

    updatePlayerUI() {
        // Set initial volume
        this.audio.volume = this.elements.volumeSlider.value;
    }
}

// Start the app
document.addEventListener('DOMContentLoaded', () => {
    window.app = new RadioApp();
});
