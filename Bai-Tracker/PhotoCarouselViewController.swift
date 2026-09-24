import UIKit

final class PhotoCarouselViewController: UIViewController {

    private let images: [UIImage]
    private var currentIndex: Int

    private let scrollView = UIScrollView()
    private let pageControl = UIPageControl()
    private let closeButton = UIButton(type: .system)
    private let counterLabel = UILabel()

    init(images: [UIImage], startIndex: Int = 0) {
        self.images = images
        self.currentIndex = startIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.95)
        setupScrollView()
        setupOverlay()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPages()
        scrollToPage(currentIndex, animated: false)
    }

    // MARK: - Setup

    private func setupScrollView() {
        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        for img in images {
            let iv = UIImageView(image: img)
            iv.contentMode = .scaleAspectFit
            scrollView.addSubview(iv)
        }
    }

    private func layoutPages() {
        let w = scrollView.bounds.width
        let h = scrollView.bounds.height
        scrollView.contentSize = CGSize(width: w * CGFloat(images.count), height: h)
        for (i, sv) in scrollView.subviews.enumerated() {
            sv.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: h)
        }
    }

    private func setupOverlay() {
        // Close button
        let closeImg = UIImage(systemName: "xmark.circle.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium))
        closeButton.setImage(closeImg, for: .normal)
        closeButton.tintColor = .white
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(closeButton)

        // Counter label
        counterLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        counterLabel.textColor = .white
        counterLabel.textAlignment = .center
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(counterLabel)
        updateCounter()

        // Page control
        pageControl.numberOfPages = images.count
        pageControl.currentPage = currentIndex
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.addTarget(self, action: #selector(pageChanged), for: .valueChanged)
        view.addSubview(pageControl)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            counterLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            pageControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            pageControl.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    // MARK: - Actions

    @objc private func close() { dismiss(animated: true) }

    @objc private func pageChanged() {
        currentIndex = pageControl.currentPage
        scrollToPage(currentIndex, animated: true)
        updateCounter()
    }

    private func scrollToPage(_ page: Int, animated: Bool) {
        let x = CGFloat(page) * scrollView.bounds.width
        scrollView.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    }

    private func updateCounter() {
        counterLabel.text = "\(currentIndex + 1) / \(images.count)"
    }
}

// MARK: - UIScrollViewDelegate

extension PhotoCarouselViewController: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let page = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        guard page != currentIndex else { return }
        currentIndex = page
        pageControl.currentPage = page
        updateCounter()
    }
}
