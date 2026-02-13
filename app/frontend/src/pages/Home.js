import React, { useState, useEffect } from 'react';
import './Home.css';

const Home = () => {
  const [healthStatus, setHealthStatus] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    const checkApiHealth = async () => {
      try {
        const response = await fetch('/api/health');
        const data = await response.json();
        setHealthStatus(data);
        setLoading(false);
      } catch (err) {
        setError('Failed to connect to API');
        setLoading(false);
      }
    };

    checkApiHealth();
  }, []);

  return (
    <div className="home-page">
      <section className="hero">
        <div className="hero-content">
          <h1>Welcome to Intermountain</h1>
          <p>Helping people live the healthiest lives possible</p>
          <button className="btn-primary">Learn More</button>
        </div>
      </section>

      <section className="features">
        <div className="feature-card">
          <h3>Quality Care</h3>
          <p>Providing exceptional healthcare services with compassion and expertise.</p>
        </div>
        <div className="feature-card">
          <h3>Innovation</h3>
          <p>Leading the way in healthcare technology and treatment approaches.</p>
        </div>
        <div className="feature-card">
          <h3>Community</h3>
          <p>Committed to improving the health and well-being of our communities.</p>
        </div>
      </section>

      <section className="api-status">
        <h2>API Status</h2>
        {loading ? (
          <p>Checking API status...</p>
        ) : error ? (
          <p className="error">{error}</p>
        ) : (
          <div className="status-card">
            <p><strong>Status:</strong> {healthStatus?.status}</p>
            <p><strong>Version:</strong> {healthStatus?.version}</p>
          </div>
        )}
      </section>
    </div>
  );
};

export default Home;
