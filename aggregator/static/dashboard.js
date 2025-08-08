document.addEventListener("DOMContentLoaded", () => {
    const categoryData = JSON.parse(document.querySelector('body').dataset.categories || '{}');
    const trendData = JSON.parse(document.querySelector('body').dataset.trend || '[]');

    new Chart(document.getElementById('categoryChart'), {
        type: 'bar',
        data: {
            labels: Object.keys(categoryData),
            datasets: [{
                label: 'Issues by Category',
                data: Object.values(categoryData),
                backgroundColor: ['#ff4d4d', '#ffa64d', '#4da6ff', '#4dff88']
            }]
        }
    });

    new Chart(document.getElementById('trendChart'), {
        type: 'line',
        data: {
            labels: trendData.map(t => t.date),
            datasets: [{
                label: 'Host Count Over Time',
                data: trendData.map(t => t.count),
                borderColor: '#4da6ff'
            }]
        }
    });
});
