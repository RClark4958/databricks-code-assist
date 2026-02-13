import React from 'react';
import './About.css';

const About = () => {
  return (
    <div className="about-page">
      <section className="about-header">
        <h1>About Intermountain</h1>
        <p>Learn more about our mission, values, and commitment to healthcare excellence.</p>
      </section>

      <section className="about-content">
        <div className="about-section">
          <h2>Our Mission</h2>
          <p>
            At Intermountain, our mission is to help people live the healthiest lives possible. 
            This mission drives everything we do, from providing exceptional patient care to 
            investing in innovative healthcare solutions and community health initiatives.
          </p>
        </div>

        <div className="about-section">
          <h2>Our Values</h2>
          <ul>
            <li><strong>Excellence:</strong> We strive for excellence in all aspects of healthcare delivery.</li>
            <li><strong>Integrity:</strong> We act with honesty and transparency in everything we do.</li>
            <li><strong>Compassion:</strong> We treat everyone with respect, dignity, and empathy.</li>
            <li><strong>Innovation:</strong> We embrace change and continuously seek better ways to improve health outcomes.</li>
            <li><strong>Teamwork:</strong> We collaborate effectively to achieve our shared goals.</li>
          </ul>
        </div>

        <div className="about-section">
          <h2>Our History</h2>
          <p>
            Founded with a commitment to providing high-quality healthcare services, 
            Intermountain has grown to become a trusted healthcare provider known for 
            clinical excellence and innovative approaches to healthcare delivery.
          </p>
          <p>
            Throughout our history, we have remained dedicated to our founding principles 
            while adapting to meet the evolving needs of the communities we serve.
          </p>
        </div>
      </section>
    </div>
  );
};

export default About;
