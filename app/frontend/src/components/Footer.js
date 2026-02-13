import React from 'react';
import './Footer.css';

const Footer = () => {
  const currentYear = new Date().getFullYear();
  
  return (
    <footer className="footer">
      <div className="footer-container">
        <div className="footer-content">
          <div className="footer-section">
            <h4>Intermountain</h4>
            <p>Helping people live the healthiest lives possible</p>
          </div>
          <div className="footer-section">
            <h4>Quick Links</h4>
            <ul>
              <li><a href="/">Home</a></li>
              <li><a href="/about">About</a></li>
            </ul>
          </div>
          <div className="footer-section">
            <h4>Contact</h4>
            <p>Email: info@intermountain.org</p>
            <p>Phone: (800) 555-1234</p>
          </div>
        </div>
        <div className="footer-bottom">
          <p>&copy; {currentYear} Intermountain. All rights reserved.</p>
        </div>
      </div>
    </footer>
  );
};

export default Footer;
