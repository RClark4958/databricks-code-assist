import React from 'react';
import { Link } from 'react-router-dom';
import './Header.css';
import logo from '../assets/intermountain-logo.png';

const Header = () => {
  return (
    <header className="header">
      <div className="header-container">
        <div className="logo-container">
          <Link to="/">
            <img src={logo} alt="Intermountain Logo" className="logo" />
          </Link>
        </div>
        <nav className="main-nav">
          <ul>
            <li><Link to="/">Home</Link></li>
            <li><Link to="/about">About</Link></li>
          </ul>
        </nav>
      </div>
    </header>
  );
};

export default Header;
