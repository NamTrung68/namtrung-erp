/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ['./src/**/*.{ts,tsx}', './public/index.html'],
  theme: {
    extend: {
      colors: {
        ink: { 50: '#f6f6f5', 100: '#ececea', 200: '#dededb', 300: '#c4c4c0', 400: '#9a9a95', 500: '#73736e', 600: '#5a5a55', 700: '#41413d', 800: '#2a2a27', 900: '#151513' },
        brand: { 50: '#f3f0ff', 100: '#e7e1ff', 500: '#7c5cff', 600: '#6a45f5', 700: '#5733db' },
      },
    },
  },
  plugins: [],
};
