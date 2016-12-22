# powervm_graphite
Collectors for PowerVm and AIX for Graphite for viewing in Grafana

This repo will contain a number of dependent and interdependent Perl scripts that will collect data from the PowerVm and AIX environment and enter the data into a Graphite database for subsequent viewing by Grafana.

It is assumed that you already have Carbon/Graphite/Whisper already setup to receive data. Google "carbon graphite whisper install" for a lot of resources on how to get it installed and configured. In many Linux distributions it will be in the main repositories.

As a side note, this repo will also contain some good examples of using the IBM HMC REST API for retrieving LPAR information

Updates, questions and suggested improvements are welcomed and encouraged
